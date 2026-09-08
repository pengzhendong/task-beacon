import SwiftUI
import UserNotifications
import TaskBeaconCore

@MainActor
final class BeaconModel: ObservableObject {
    @Published var tasks: [TaskRecord] = []
    @Published var collectors: [CollectorRecord] = []
    @Published var connectionError: String?

    private var refreshTask: Task<Void, Never>?
    private var loadedOnce = false
    private var attemptedDaemonStart = false
    private var notificationsAllowed = false
    private var preparingForUpdate = false

    var activeCount: Int { tasks.filter { !$0.status.isTerminal }.count }
    var attentionCount: Int { tasks.filter { $0.status == .waiting || $0.status == .failed }.count }

    init() {
        startRefreshing()
    }

    deinit { refreshTask?.cancel() }

    func refresh() async {
        guard !preparingForUpdate else { return }
        do {
            let response = try await Task.detached {
                try TaskBeaconClient().send(WireRequest(action: "snapshot"))
            }.value
            guard !preparingForUpdate else { return }
            guard response.ok, let snapshot = response.snapshot else {
                throw TaskBeaconError.connection(response.message ?? "invalid service response")
            }
            if loadedOnce { notifyTransitions(from: tasks, to: snapshot.tasks) }
            tasks = snapshot.tasks
            collectors = snapshot.collectors
            connectionError = nil
            loadedOnce = true
        } catch {
            guard !preparingForUpdate else { return }
            connectionError = error.localizedDescription
            if !attemptedDaemonStart {
                attemptedDaemonStart = true
                startDaemonIfAvailable()
            }
        }
    }

    func prepareForApplicationUpdate() {
        preparingForUpdate = true
        refreshTask?.cancel()
        let daemon = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/taskbeacond")
        guard FileManager.default.isExecutableFile(atPath: daemon.path) else { return }
        do {
            let response = try TaskBeaconClient(timeout: 5).send(WireRequest(
                action: "service.prepare-update", expectedExecutablePath: daemon.standardizedFileURL.path
            ))
            if !response.ok { NSLog("TaskBeacon update handoff: %@", response.message ?? "service declined") }
        } catch {
            // A stopped daemon needs no handoff. Never terminate another installation or a PID from disk.
            NSLog("TaskBeacon update handoff: %@", error.localizedDescription)
        }
    }

    func resumeAfterUpdateFailure() {
        preparingForUpdate = false
        attemptedDaemonStart = false
        startRefreshing()
    }

    private func startRefreshing() {
        refreshTask = Task { [weak self] in
            await self?.prepareNotifications()
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func prepareNotifications() async {
        notificationsAllowed = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) == true
    }

    private func notifyTransitions(from oldTasks: [TaskRecord], to newTasks: [TaskRecord]) {
        guard notificationsAllowed else { return }
        let oldStatuses = Dictionary(uniqueKeysWithValues: oldTasks.map { ($0.id, $0.status) })
        for task in newTasks where oldStatuses[task.id] != task.status {
            guard task.status == .waiting || task.status == .failed || task.status == .completed else { continue }
            let content = UNMutableNotificationContent()
            content.title = task.title
            content.body = task.message ?? notificationText(for: task.status)
            content.sound = task.status == .completed ? nil : .default
            let request = UNNotificationRequest(identifier: "taskbeacon-\(task.id)-\(task.status.rawValue)",
                                                content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func notificationText(for status: TaskStatus) -> String {
        switch status {
        case .waiting: "任务正在等待处理"
        case .failed: "任务执行失败"
        case .completed: "任务已完成"
        default: "任务状态已更新"
        }
    }

    private func startDaemonIfAvailable() {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/taskbeacond")
        let sibling = executable.deletingLastPathComponent().appendingPathComponent("taskbeacond")
        let daemon = FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : sibling
        guard FileManager.default.isExecutableFile(atPath: daemon.path) else { return }
        do {
            try FileManager.default.createDirectory(at: RuntimePaths.dataDirectory, withIntermediateDirectories: true)
            let logURL = RuntimePaths.dataDirectory.appendingPathComponent("taskbeacond.log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let log = try FileHandle(forWritingTo: logURL)
            try log.seekToEnd()
            let process = Process()
            process.executableURL = daemon
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = log
            process.standardError = log
            try process.run()
        } catch {
            connectionError = "无法启动服务：\(error.localizedDescription)"
        }
    }
}

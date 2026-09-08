import SwiftUI
import AppKit
import UserNotifications
import Sparkle
import TaskBeaconCore

@main
struct TaskBeaconMenuApp: App {
    @StateObject private var model: BeaconModel
    @StateObject private var updater: UpdateController

    init() {
        let model = BeaconModel()
        _model = StateObject(wrappedValue: model)
        _updater = StateObject(wrappedValue: UpdateController(model: model))
    }

    var body: some Scene {
        MenuBarExtra {
            BeaconMenu(model: model, updater: updater)
                .frame(width: 390, height: panelHeight)
                .animation(.easeInOut(duration: 0.18), value: model.tasks.count)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .renderingMode(MenuBarIcon.image.isTemplate ? .template : .original)
                .interpolation(.high)
                .frame(width: 22, height: 22)
                .accessibilityLabel("TaskBeacon")
                .accessibilityValue("\(model.activeCount) 个进行中，\(model.attentionCount) 个需处理")
                .help("TaskBeacon · \(model.activeCount) 个进行中 · \(model.attentionCount) 个需处理")
        }
        .menuBarExtraStyle(.window)
    }

    private var panelHeight: CGFloat {
        min(520, max(230, 140 + CGFloat(model.tasks.count) * 90))
    }
}

@MainActor
private enum MenuBarIcon {
    static let image: NSImage = {
        let icon: NSImage
        if let url = Bundle.main.url(forResource: "TaskBeaconStatus", withExtension: "png"),
           let bundledIcon = NSImage(contentsOf: url) {
            icon = bundledIcon
            icon.isTemplate = false
        } else {
            icon = NSImage(systemSymbolName: "terminal", accessibilityDescription: "TaskBeacon")
                ?? NSImage(size: NSSize(width: 22, height: 22))
            icon.isTemplate = true
        }
        // Keep the source pixels for Retina rendering while sizing the status item in points.
        icon.size = NSSize(width: 22, height: 22)
        return icon
    }()
}

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    private(set) var controller: SPUStandardUpdaterController!
    private let model: BeaconModel
    private var updateWillInstall = false
    private var daemonPrepared = false

    init(model: BeaconModel) {
        self.model = model
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate),
                                               name: NSApplication.willTerminateNotification, object: nil)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        updateWillInstall = true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        updateWillInstall = true
        return false
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        prepareDaemonForUpdate()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        updateWillInstall = false
        if daemonPrepared {
            daemonPrepared = false
            model.resumeAfterUpdateFailure()
        }
    }

    @objc private func applicationWillTerminate() {
        if updateWillInstall { prepareDaemonForUpdate() }
    }

    private func prepareDaemonForUpdate() {
        guard !daemonPrepared else { return }
        daemonPrepared = true
        model.prepareForApplicationUpdate()
    }
}

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

    private func startRefreshing() {
        refreshTask = Task { [weak self] in
            await self?.prepareNotifications()
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
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

struct BeaconMenu: View {
    @ObservedObject var model: BeaconModel
    @ObservedObject var updater: UpdateController

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = model.connectionError {
                EmptyState(title: "服务未连接", systemImage: "bolt.slash", detail: error)
            } else if model.tasks.isEmpty {
                EmptyState(title: "暂无任务", systemImage: "checkmark.circle",
                           detail: "通过 CLI 或 MCP 注册任务后会显示在这里")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(groups, id: \.key) { group in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(group.key)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(group.value.count)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                                ForEach(group.value) { task in
                                    TaskRow(task: task, collector: collector(for: task.id))
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.3))
            }
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("TaskBeacon")
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(brandGreen).frame(width: 6, height: 6)
                    Text("\(model.activeCount) 个进行中")
                    if model.attentionCount > 0 {
                        Text("· \(model.attentionCount) 个需处理")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .background(Color.primary.opacity(0.055), in: Circle())
            .help("立即刷新")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button { updater.checkForUpdates() } label: {
                Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.plain)
            Spacer()
            Text("每 2 秒刷新")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Divider().frame(height: 14)
            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("退出 TaskBeacon")
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider() }
    }

    private var groups: [(key: String, value: [TaskRecord])] {
        Dictionary(grouping: model.tasks) { task in
            [task.project, task.hostID].compactMap { $0 }.joined(separator: " · ")
        }.map { (key: $0.key.isEmpty ? "未分组" : $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }
    }

    private func collector(for taskID: String) -> CollectorRecord? {
        model.collectors.first { $0.taskID == taskID }
    }

    private var brandGreen: Color {
        Color(red: 0.38, green: 0.55, blue: 0.45)
    }
}

struct EmptyState: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 42, height: 42)
                .background(Color.primary.opacity(0.05), in: Circle())
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
    }
}

struct TaskRow: View {
    let task: TaskRecord
    let collector: CollectorRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(task.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(task.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                Text(statusText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.12), in: Capsule())
                if let target = task.target, let url = targetURL(target) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .help("打开结果")
                }
            }
            if task.stage != nil || task.message != nil {
                HStack(spacing: 4) {
                    if let stage = task.stage {
                        Text(stage).fontWeight(.medium).foregroundStyle(.primary)
                    }
                    if task.stage != nil, task.message != nil {
                        Text("·").foregroundStyle(.tertiary)
                    }
                    if let message = task.message {
                        Text(message).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            if let progress = task.progress, let fraction = progress.fraction {
                HStack(spacing: 8) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(color)
                    Text(progressText(progress))
                        .font(.caption2).foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            if let error = collector?.lastError {
                Label("采集异常：\(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.76),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.035), radius: 2, y: 1)
    }

    private var statusText: String {
        switch task.status {
        case .running: "进行中"
        case .waiting: "等待处理"
        case .failed: "失败"
        case .cancelled: "已取消"
        case .completed: "已完成"
        }
    }
    private var color: Color {
        switch task.status {
        case .running: Color(red: 0.38, green: 0.55, blue: 0.45)
        case .waiting: .orange
        case .failed: .red
        case .cancelled: .secondary
        case .completed: .green
        }
    }
    private func display(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
    private func progressText(_ progress: WorkProgress) -> String {
        let unit = progress.unit.map { " \($0)" } ?? ""
        return "\(display(progress.completed))/\(display(progress.total))\(unit)"
    }
    private func targetURL(_ target: String) -> URL? {
        if target.hasPrefix("/") { return URL(fileURLWithPath: target) }
        return URL(string: target)
    }
}

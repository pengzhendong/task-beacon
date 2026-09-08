import Foundation
import Darwin
import TaskBeaconCore

@main
struct TaskBeaconDaemon {
    private static let collectorProcesses = CollectorProcesses()
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        let store = TaskStore()
        do {
            try await store.load()
            let descriptor = try makeServerSocket(path: RuntimePaths.socketPath)
            try FileManager.default.createDirectory(at: RuntimePaths.dataDirectory, withIntermediateDirectories: true)
            try Data("\(getpid())\n".utf8).write(to: RuntimePaths.dataDirectory.appendingPathComponent("taskbeacond.pid"), options: .atomic)
            print("TaskBeacon service listening at \(RuntimePaths.socketPath)")

            Task { await runCollectorScheduler(store: store) }

            while true {
                let client = await nextClient(descriptor)
                if client < 0 {
                    if errno == EINTR { continue }
                    throw TaskBeaconError.connection("accept failed: \(String(cString: strerror(errno)))")
                }
                Task {
                    await serve(client: client, store: store)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("taskbeacond: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func nextClient(_ descriptor: Int32) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var address = sockaddr()
                var length = socklen_t(MemoryLayout<sockaddr>.size)
                continuation.resume(returning: accept(descriptor, &address, &length))
            }
        }
    }

    private static func makeServerSocket(path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TaskBeaconError.connection("cannot create server socket") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            throw TaskBeaconError.connection("socket path is too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            let bytes = path.utf8CString
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
                _ = bytes.withUnsafeBufferPointer { source in
                    memcpy(destination, source.baseAddress!, source.count)
                }
            }
        }

        if FileManager.default.fileExists(atPath: path) {
            let probe = TaskBeaconClient(socketPath: path)
            if (try? probe.send(WireRequest(action: "ping")))?.ok == true {
                close(descriptor)
                throw TaskBeaconError.connection("another TaskBeacon service is already running")
            }
            unlink(path)
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(descriptor)
            throw TaskBeaconError.connection("bind failed: \(String(cString: strerror(errno)))")
        }
        guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
            close(descriptor)
            unlink(path)
            throw TaskBeaconError.connection("cannot restrict socket permissions")
        }
        guard listen(descriptor, 32) == 0 else {
            close(descriptor)
            throw TaskBeaconError.connection("listen failed: \(String(cString: strerror(errno)))")
        }
        return descriptor
    }

    private static func serve(client: Int32, store: TaskStore) async {
        var clientClosed = false
        defer { if !clientClosed { close(client) } }
        do {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while data.count < 1_048_576 {
                let count = Darwin.read(client, &buffer, buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer[0..<count])
                if data.last == 0x0A { break }
            }
            let request = try JSONCoding.decoder().decode(WireRequest.self, from: data)
            if request.action == "service.prepare-update" {
                var peerUID: uid_t = 0
                var peerGID: gid_t = 0
                guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == getuid() else {
                    throw TaskBeaconError.invalid("only the current user may restart this service")
                }
                let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
                guard request.expectedExecutablePath == executable else {
                    throw TaskBeaconError.invalid("the service belongs to a different TaskBeacon installation")
                }
                try await store.prepareForUpdate()
                collectorProcesses.stopForUpdate()
                // The store is now read-only; no late collector or RPC can overwrite restored state.
                unlink(RuntimePaths.socketPath)
                let pidFile = RuntimePaths.dataDirectory.appendingPathComponent("taskbeacond.pid")
                if (try? String(contentsOf: pidFile, encoding: .utf8)) == "\(getpid())\n" {
                    try? FileManager.default.removeItem(at: pidFile)
                }
                if let encoded = try? JSONCoding.encoder().encode(WireResponse(ok: true, message: "ready for update")) {
                    try? writeAll(encoded, to: client)
                }
                close(client)
                clientClosed = true
                exit(0)
            }
            let response = await handle(request, store: store)
            let encoded = try JSONCoding.encoder().encode(response)
            try writeAll(encoded, to: client)
        } catch {
            let response = WireResponse(ok: false, message: error.localizedDescription)
            if let encoded = try? JSONCoding.encoder().encode(response) {
                try? writeAll(encoded, to: client)
            }
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw TaskBeaconError.connection("failed to write response") }
                offset += count
            }
        }
    }

    private static func handle(_ request: WireRequest, store: TaskStore) async -> WireResponse {
        do {
            switch request.action {
            case "ping":
                return WireResponse(ok: true, message: "pong")
            case "register":
                guard let task = request.task else { throw TaskBeaconError.invalid("task is required") }
                return WireResponse(ok: true, task: try await store.register(task))
            case "update":
                guard let taskID = request.taskID, let patch = request.patch else {
                    throw TaskBeaconError.invalid("task_id and patch are required")
                }
                let result = try await store.update(
                    taskID: taskID,
                    eventID: request.eventID ?? UUID().uuidString,
                    sequence: request.sequence,
                    observedAt: request.observedAt ?? Date(),
                    source: request.source ?? "direct",
                    patch: patch
                )
                return WireResponse(ok: true, ignored: result.1, task: result.0)
            case "list":
                return WireResponse(ok: true, tasks: await store.listTasks())
            case "snapshot":
                return WireResponse(ok: true, snapshot: await store.snapshot())
            case "collector.register":
                guard let collector = request.collector else { throw TaskBeaconError.invalid("collector is required") }
                return WireResponse(ok: true, collector: try await store.registerCollector(collector))
            case "collector.state":
                guard let id = request.collectorID, let state = request.collectorState else {
                    throw TaskBeaconError.invalid("collector_id and state are required")
                }
                return WireResponse(ok: true, collector: try await store.setCollectorState(id: id, state: state))
            case "collector.remove":
                guard let id = request.collectorID else { throw TaskBeaconError.invalid("collector_id is required") }
                try await store.removeCollector(id: id)
                return WireResponse(ok: true)
            case "collector.list":
                return WireResponse(ok: true, collectors: await store.listCollectors())
            default:
                throw TaskBeaconError.invalid("unknown action: \(request.action)")
            }
        } catch {
            return WireResponse(ok: false, message: error.localizedDescription)
        }
    }

    private static func runCollectorScheduler(store: TaskStore) async {
        while !Task.isCancelled {
            let due = await store.dueCollectors()
            for collector in due {
                do { try await store.markCollectorStarted(id: collector.id) }
                catch { continue }
                Task { await execute(collector: collector, store: store) }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private static func execute(collector: CollectorRecord, store: TaskStore) async {
        do {
            let data = try await run(command: collector.command,
                                     workingDirectory: collector.workingDirectory,
                                     timeout: collector.timeoutSeconds)
            let output = try JSONCoding.decoder().decode(CollectorOutput.self, from: data)
            let status: TaskStatus? = output.done == true ? .completed : output.status
            let patch = TaskPatch(status: status, stage: output.stage, message: output.message,
                                  progress: output.progress, result: output.result, target: output.target)
            _ = try await store.update(taskID: collector.taskID, eventID: UUID().uuidString,
                                       sequence: nil, observedAt: Date(), source: "collector:\(collector.id)", patch: patch)
            try await store.recordCollectorRun(id: collector.id, success: true, error: nil)
            if status?.isTerminal == true {
                _ = try? await store.setCollectorState(id: collector.id, state: .paused)
            }
        } catch {
            try? await store.recordCollectorRun(id: collector.id, success: false,
                                                error: error.localizedDescription)
        }
    }

    private static func run(command: String, workingDirectory: String?, timeout: Double) async throws -> Data {
        try await Task.detached {
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.standardOutput = output
            process.standardError = errors
            if let workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            }
            try collectorProcesses.start(process)
            defer { collectorProcesses.finished(process) }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline && !collectorProcesses.isStopping {
                usleep(50_000)
            }
            guard !collectorProcesses.isStopping else {
                throw TaskBeaconError.connection("collector stopped for application update")
            }
            if process.isRunning {
                process.terminate()
                throw TaskBeaconError.connection("collector timed out after \(timeout) seconds")
            }
            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            if process.terminationStatus != 0 {
                let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw TaskBeaconError.connection("collector exited \(process.terminationStatus): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return stdout
        }.value
    }
}

/// Tracks only subprocesses launched by this daemon; it never searches for or kills business tasks.
private final class CollectorProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]
    private var stopping = false

    var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    func start(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopping else { throw TaskBeaconError.connection("service is preparing for an update") }
        try process.run()
        processes[ObjectIdentifier(process)] = process
    }

    func finished(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        processes.removeValue(forKey: ObjectIdentifier(process))
    }

    func stopForUpdate() {
        lock.lock()
        stopping = true
        let running = Array(processes.values)
        lock.unlock()
        for process in running where process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(1)
        while running.contains(where: \.isRunning) && Date() < deadline { usleep(20_000) }
        for process in running where process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    }
}

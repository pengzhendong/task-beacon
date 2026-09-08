import Foundation
import Darwin
import TaskBeaconCore

@main
struct TaskBeaconCLI {
    static func main() {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else { return usage() }
            arguments.removeFirst()
            if ["help", "--help", "-h"].contains(command) { return usage() }
            if command == "daemon" { return try daemon(arguments) }

            let client = TaskBeaconClient()
            let response: WireResponse
            switch command {
            case "register": response = try register(arguments, client: client)
            case "update": response = try update(arguments, client: client, forcedStatus: nil)
            case "complete": response = try update(arguments, client: client, forcedStatus: .completed)
            case "cancel": response = try update(arguments, client: client, forcedStatus: .cancelled)
            case "list": response = try client.send(WireRequest(action: "list"))
            case "snapshot": response = try client.send(WireRequest(action: "snapshot"))
            case "collector": response = try collector(arguments, client: client)
            default: throw TaskBeaconError.invalid("unknown command: \(command)")
            }
            guard response.ok else { throw TaskBeaconError.invalid(response.message ?? "request failed") }
            if arguments.contains("--json") || command == "snapshot" {
                print(String(data: try JSONCoding.encoder(pretty: true).encode(response), encoding: .utf8)!)
            } else {
                printHuman(response)
            }
        } catch {
            FileHandle.standardError.write(Data("taskbeacon: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func register(_ args: [String], client: TaskBeaconClient) throws -> WireResponse {
        let options = Options(args)
        let id = options.value("--id") ?? UUID().uuidString
        guard let title = options.value("--title") else { throw TaskBeaconError.invalid("--title is required") }
        let task = TaskRecord(
            id: id,
            provider: options.value("--provider") ?? "cli",
            hostID: options.value("--host") ?? Host.current().localizedName ?? "localhost",
            sessionID: options.value("--session"), project: options.value("--project"),
            parentTaskID: options.value("--parent"), title: title,
            stage: options.value("--stage"), message: options.value("--message"),
            target: options.value("--target")
        )
        return try client.send(WireRequest(action: "register", task: task))
    }

    private static func update(_ args: [String], client: TaskBeaconClient,
                               forcedStatus: TaskStatus?) throws -> WireResponse {
        let options = Options(args)
        guard let taskID = options.positionals.first else { throw TaskBeaconError.invalid("task id is required") }
        let status: TaskStatus?
        if let forcedStatus { status = forcedStatus }
        else if let raw = options.value("--status") {
            guard let parsed = TaskStatus(rawValue: raw) else { throw TaskBeaconError.invalid("invalid status: \(raw)") }
            status = parsed
        } else { status = nil }

        var progress: WorkProgress?
        if let completed = options.double("--completed"), let total = options.double("--total") {
            progress = WorkProgress(completed: completed, total: total, unit: options.value("--unit"))
        }
        let patch = TaskPatch(status: status, stage: options.value("--stage"),
                              message: options.value("--message"), progress: progress,
                              result: options.value("--result"), target: options.value("--target"))
        return try client.send(WireRequest(action: "update", taskID: taskID,
                                           eventID: options.value("--event-id") ?? UUID().uuidString,
                                           sequence: options.int64("--sequence"), observedAt: Date(),
                                           source: options.value("--source") ?? "cli", patch: patch))
    }

    private static func collector(_ args: [String], client: TaskBeaconClient) throws -> WireResponse {
        guard let subcommand = args.first else { throw TaskBeaconError.invalid("collector subcommand is required") }
        let tail = Array(args.dropFirst())
        let options = Options(tail)
        switch subcommand {
        case "add":
            guard let taskID = options.value("--task") else { throw TaskBeaconError.invalid("--task is required") }
            guard let command = options.value("--command") else { throw TaskBeaconError.invalid("--command is required") }
            let collector = CollectorRecord(
                id: options.value("--id") ?? UUID().uuidString,
                taskID: taskID, command: command, workingDirectory: options.value("--cwd"),
                intervalSeconds: options.double("--interval") ?? 30,
                timeoutSeconds: options.double("--timeout") ?? 10
            )
            return try client.send(WireRequest(action: "collector.register", collector: collector))
        case "list":
            return try client.send(WireRequest(action: "collector.list"))
        case "pause", "resume":
            guard let id = options.positionals.first else { throw TaskBeaconError.invalid("collector id is required") }
            return try client.send(WireRequest(action: "collector.state", collectorID: id,
                                               collectorState: subcommand == "pause" ? .paused : .active))
        case "remove":
            guard let id = options.positionals.first else { throw TaskBeaconError.invalid("collector id is required") }
            return try client.send(WireRequest(action: "collector.remove", collectorID: id))
        default:
            throw TaskBeaconError.invalid("unknown collector subcommand: \(subcommand)")
        }
    }

    private static func daemon(_ args: [String]) throws {
        let subcommand = args.first ?? "status"
        let client = TaskBeaconClient()
        switch subcommand {
        case "status":
            if (try? client.send(WireRequest(action: "ping")))?.ok == true {
                print("TaskBeacon service is running")
            } else {
                print("TaskBeacon service is stopped")
                exit(1)
            }
        case "start":
            if (try? client.send(WireRequest(action: "ping")))?.ok == true {
                print("TaskBeacon service is already running")
                return
            }
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            let executableDirectory = executable.deletingLastPathComponent()
            let candidates = [
                executableDirectory.appendingPathComponent("taskbeacond"),
                executableDirectory
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Helpers/taskbeacond")
            ]
            guard let daemonURL = candidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path)
            }) else {
                throw TaskBeaconError.notFound("taskbeacond was not found beside the CLI or in the app bundle")
            }
            try FileManager.default.createDirectory(at: RuntimePaths.dataDirectory, withIntermediateDirectories: true)
            let logURL = RuntimePaths.dataDirectory.appendingPathComponent("taskbeacond.log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let log = try FileHandle(forWritingTo: logURL)
            try log.seekToEnd()
            let process = Process()
            process.executableURL = daemonURL
            process.standardOutput = log
            process.standardError = log
            try process.run()
            for _ in 0..<30 {
                Thread.sleep(forTimeInterval: 0.1)
                if (try? client.send(WireRequest(action: "ping")))?.ok == true {
                    print("TaskBeacon service started (pid \(process.processIdentifier))")
                    return
                }
            }
            throw TaskBeaconError.connection("service did not become ready; see \(logURL.path)")
        case "stop":
            let response = try client.send(WireRequest(action: "service.shutdown"))
            guard response.ok else {
                throw TaskBeaconError.connection(response.message ?? "service refused to stop")
            }
            print("TaskBeacon service stopped")
        default:
            throw TaskBeaconError.invalid("unknown daemon subcommand: \(subcommand)")
        }
    }

    private static func printHuman(_ response: WireResponse) {
        if let task = response.task {
            print("\(task.id)  \(task.status.rawValue)  \(task.title)")
            if response.ignored == true { print("event ignored (duplicate or out of order)") }
        } else if let tasks = response.tasks {
            if tasks.isEmpty { print("No tasks") }
            for task in tasks {
                let count = task.progress.map { " \(format($0.completed))/\(format($0.total))\($0.unit.map { " \($0)" } ?? "")" } ?? ""
                print("\(task.id)  \(task.status.rawValue)  \(task.title)\(count)")
            }
        } else if let collector = response.collector {
            print("\(collector.id)  \(collector.state.rawValue)  task=\(collector.taskID)")
        } else if let collectors = response.collectors {
            if collectors.isEmpty { print("No collectors") }
            for collector in collectors {
                let health = collector.lastError.map { " error=\($0)" } ?? ""
                print("\(collector.id)  \(collector.state.rawValue)  task=\(collector.taskID)\(health)")
            }
        } else {
            print(response.message ?? "OK")
        }
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    private static func usage() {
        print("""
        TaskBeacon CLI

          taskbeacon daemon start|stop|status
          taskbeacon register --title TITLE [--id ID] [--provider NAME] [--project NAME]
          taskbeacon update TASK_ID [--status running|waiting|failed] [--stage TEXT] [--message TEXT]
                    [--completed N --total N --unit NAME] [--event-id ID] [--sequence N]
          taskbeacon complete TASK_ID [--result TEXT] [--target URL_OR_PATH]
          taskbeacon cancel TASK_ID [--message TEXT]
          taskbeacon list [--json]
          taskbeacon snapshot
          taskbeacon collector add --task TASK_ID --command COMMAND [--interval SEC] [--timeout SEC]
          taskbeacon collector list|pause|resume|remove [COLLECTOR_ID]
        """)
    }
}

private struct Options {
    let values: [String: String]
    let positionals: [String]

    init(_ arguments: [String]) {
        var values: [String: String] = [:]
        var positionals: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--"), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                values[argument] = arguments[index + 1]
                index += 2
            } else if argument.hasPrefix("--") {
                values[argument] = "true"
                index += 1
            } else {
                positionals.append(argument)
                index += 1
            }
        }
        self.values = values
        self.positionals = positionals
    }

    func value(_ name: String) -> String? { values[name] }
    func double(_ name: String) -> Double? { values[name].flatMap(Double.init) }
    func int64(_ name: String) -> Int64? { values[name].flatMap(Int64.init) }
}

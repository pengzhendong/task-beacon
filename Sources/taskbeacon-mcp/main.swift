import Foundation
import TaskBeaconCore

@main
struct TaskBeaconMCP {
    private static let latestProtocolVersion = "2025-11-25"
    private static let supportedProtocolVersions = [latestProtocolVersion, "2025-06-18"]

    static func main() {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let response = handle(request),
               let output = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
               let text = String(data: output, encoding: .utf8) {
                print(text)
                fflush(stdout)
            }
        }
    }

    private static func handle(_ request: [String: Any]) -> [String: Any]? {
        let id = request["id"] ?? NSNull()
        guard let method = request["method"] as? String else {
            return failure(id: id, code: -32600, message: "invalid request")
        }
        switch method {
        case "notifications/initialized": return nil
        case "initialize":
            let requestedVersion = (request["params"] as? [String: Any])?["protocolVersion"] as? String
            let negotiatedVersion = requestedVersion.flatMap {
                supportedProtocolVersions.contains($0) ? $0 : nil
            } ?? latestProtocolVersion
            return success(id: id, result: [
                "protocolVersion": negotiatedVersion,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "taskbeacon-mcp", "version": "0.1.7"],
                "instructions": "Use TaskBeacon for work likely to take over a minute. Register once at the start, update only at meaningful stage or measurable progress changes, then complete or cancel it. Reuse the same task_id. Never invent percentages: omit completed and total unless progress is measurable."
            ])
        case "tools/list":
            return success(id: id, result: ["tools": tools])
        case "tools/call":
            guard let params = request["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                return failure(id: id, code: -32602, message: "missing tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try call(name: name, arguments: arguments)
                return success(id: id, result: ["content": [["type": "text", "text": text]]])
            } catch {
                return success(id: id, result: [
                    "content": [["type": "text", "text": error.localizedDescription]],
                    "isError": true
                ])
            }
        default:
            return failure(id: id, code: -32601, message: "method not found")
        }
    }

    private static func call(name: String, arguments: [String: Any]) throws -> String {
        let client = TaskBeaconClient()
        let response: WireResponse
        switch name {
        case "task_register":
            guard let title = arguments.string("title") else { throw TaskBeaconError.invalid("title is required") }
            let task = TaskRecord(
                id: arguments.string("task_id") ?? UUID().uuidString,
                provider: arguments.string("provider") ?? "mcp",
                hostID: arguments.string("host_id") ?? Host.current().localizedName ?? "localhost",
                sessionID: arguments.string("session_id"), project: arguments.string("project"),
                parentTaskID: arguments.string("parent_task_id"), title: title,
                stage: arguments.string("stage"), message: arguments.string("message"),
                target: arguments.string("target")
            )
            response = try client.send(WireRequest(action: "register", task: task))
        case "task_update", "task_complete", "task_cancel":
            guard let taskID = arguments.string("task_id") else { throw TaskBeaconError.invalid("task_id is required") }
            let status: TaskStatus?
            if name == "task_complete" { status = .completed }
            else if name == "task_cancel" { status = .cancelled }
            else if let raw = arguments.string("status") {
                guard let parsed = TaskStatus(rawValue: raw) else { throw TaskBeaconError.invalid("invalid status") }
                status = parsed
            } else { status = nil }
            var progress: WorkProgress?
            if let completed = arguments.double("completed"), let total = arguments.double("total") {
                progress = WorkProgress(completed: completed, total: total, unit: arguments.string("unit"))
            }
            let patch = TaskPatch(status: status, stage: arguments.string("stage"),
                                  message: arguments.string("message"), progress: progress,
                                  result: arguments.string("result"), target: arguments.string("target"))
            response = try client.send(WireRequest(
                action: "update", taskID: taskID,
                eventID: arguments.string("event_id") ?? UUID().uuidString,
                sequence: arguments.int64("sequence"), observedAt: Date(),
                source: arguments.string("source") ?? "mcp", patch: patch
            ))
        case "task_list":
            response = try client.send(WireRequest(action: "list"))
        case "collector_register":
            guard let taskID = arguments.string("task_id"), let command = arguments.string("command") else {
                throw TaskBeaconError.invalid("task_id and command are required")
            }
            let collector = CollectorRecord(
                id: arguments.string("collector_id") ?? UUID().uuidString,
                taskID: taskID, command: command, workingDirectory: arguments.string("working_directory"),
                intervalSeconds: arguments.double("interval_seconds") ?? 30,
                timeoutSeconds: arguments.double("timeout_seconds") ?? 10
            )
            response = try client.send(WireRequest(action: "collector.register", collector: collector))
        case "collector_run":
            guard let collectorID = arguments.string("collector_id") else {
                throw TaskBeaconError.invalid("collector_id is required")
            }
            response = try client.send(WireRequest(action: "collector.run", collectorID: collectorID))
        default:
            throw TaskBeaconError.invalid("unknown tool: \(name)")
        }
        guard response.ok else { throw TaskBeaconError.invalid(response.message ?? "request failed") }
        return String(data: try JSONCoding.encoder(pretty: true).encode(response), encoding: .utf8)!
    }

    private static func success(id: Any, result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func failure(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static var tools: [[String: Any]] { [
        tool("task_register", "Register a long-running task", properties: [
            "task_id": string(), "title": string(), "provider": string(), "host_id": string(),
            "session_id": string(), "project": string(), "parent_task_id": string(),
            "stage": string(), "message": string(), "target": string()
        ], required: ["title"]),
        tool("task_update", "Report a task status, stage, message, or measurable progress", properties: [
            "task_id": string(), "status": enumeration(TaskStatus.allCases.map(\.rawValue)),
            "stage": string(), "message": string(), "completed": number(), "total": number(),
            "unit": string(), "event_id": string(), "sequence": integer(), "source": string(),
            "result": string(), "target": string()
        ], required: ["task_id"]),
        tool("task_complete", "Mark a task completed and attach its result", properties: [
            "task_id": string(), "message": string(), "result": string(), "target": string(), "event_id": string()
        ], required: ["task_id"]),
        tool("task_cancel", "Mark a task cancelled", properties: [
            "task_id": string(), "message": string(), "event_id": string()
        ], required: ["task_id"]),
        tool("task_list", "List all known tasks", properties: [:], required: []),
        tool("collector_register", "Register an independent command that emits one JSON progress object per run", properties: [
            "collector_id": string(), "task_id": string(), "command": string(),
            "working_directory": string(), "interval_seconds": number(), "timeout_seconds": number()
        ], required: ["task_id", "command"]),
        tool("collector_run", "Run a registered collector immediately", properties: [
            "collector_id": string()
        ], required: ["collector_id"]),
    ] }

    private static func tool(_ name: String, _ description: String,
                             properties: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required,
                         "additionalProperties": false]]
    }
    private static func string() -> [String: Any] { ["type": "string"] }
    private static func number() -> [String: Any] { ["type": "number"] }
    private static func integer() -> [String: Any] { ["type": "integer"] }
    private static func enumeration(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func double(_ key: String) -> Double? {
        if let number = self[key] as? NSNumber { return number.doubleValue }
        return (self[key] as? String).flatMap(Double.init)
    }
    func int64(_ key: String) -> Int64? {
        if let number = self[key] as? NSNumber { return number.int64Value }
        return (self[key] as? String).flatMap(Int64.init)
    }
}

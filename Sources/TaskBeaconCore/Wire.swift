import Foundation

public struct WireRequest: Codable, Sendable {
    public var action: String
    public var task: TaskRecord?
    public var taskID: String?
    public var eventID: String?
    public var sequence: Int64?
    public var observedAt: Date?
    public var source: String?
    public var patch: TaskPatch?
    public var collector: CollectorRecord?
    public var collectorID: String?
    public var collectorState: CollectorState?
    public var expectedExecutablePath: String?

    public init(action: String, task: TaskRecord? = nil, taskID: String? = nil,
                eventID: String? = nil, sequence: Int64? = nil, observedAt: Date? = nil,
                source: String? = nil, patch: TaskPatch? = nil,
                collector: CollectorRecord? = nil, collectorID: String? = nil,
                collectorState: CollectorState? = nil, expectedExecutablePath: String? = nil) {
        self.action = action
        self.task = task
        self.taskID = taskID
        self.eventID = eventID
        self.sequence = sequence
        self.observedAt = observedAt
        self.source = source
        self.patch = patch
        self.collector = collector
        self.collectorID = collectorID
        self.collectorState = collectorState
        self.expectedExecutablePath = expectedExecutablePath
    }
}

public struct WireResponse: Codable, Sendable {
    public var ok: Bool
    public var message: String?
    public var ignored: Bool?
    public var task: TaskRecord?
    public var tasks: [TaskRecord]?
    public var collector: CollectorRecord?
    public var collectors: [CollectorRecord]?
    public var snapshot: StateSnapshot?

    public init(ok: Bool, message: String? = nil, ignored: Bool? = nil,
                task: TaskRecord? = nil, tasks: [TaskRecord]? = nil,
                collector: CollectorRecord? = nil, collectors: [CollectorRecord]? = nil,
                snapshot: StateSnapshot? = nil) {
        self.ok = ok
        self.message = message
        self.ignored = ignored
        self.task = task
        self.tasks = tasks
        self.collector = collector
        self.collectors = collectors
        self.snapshot = snapshot
    }
}

public enum TaskBeaconError: LocalizedError {
    case invalid(String)
    case notFound(String)
    case connection(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .notFound(let message), .connection(let message): message
        }
    }
}

public enum JSONCoding {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum RuntimePaths {
    public static var socketPath: String {
        ProcessInfo.processInfo.environment["TASKBEACON_SOCKET"]
            ?? "/tmp/taskbeacon-\(getuid()).sock"
    }

    public static var dataDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["TASKBEACON_DATA_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TaskBeacon", isDirectory: true)
    }

    public static var stateFile: URL { dataDirectory.appendingPathComponent("state.json") }
}

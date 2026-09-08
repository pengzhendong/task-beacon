import Foundation

public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case running
    case waiting
    case failed
    case cancelled
    case completed

    public var isTerminal: Bool { self == .failed || self == .cancelled || self == .completed }
}

public struct WorkProgress: Codable, Equatable, Sendable {
    public var completed: Double
    public var total: Double
    public var unit: String?

    public init(completed: Double, total: Double, unit: String? = nil) {
        self.completed = completed
        self.total = total
        self.unit = unit
    }

    public var fraction: Double? {
        guard total > 0, completed >= 0 else { return nil }
        return min(completed / total, 1)
    }
}

public struct TaskRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var provider: String
    public var hostID: String
    public var sessionID: String?
    public var project: String?
    public var parentTaskID: String?
    public var title: String
    public var status: TaskStatus
    public var stage: String?
    public var message: String?
    public var progress: WorkProgress?
    public var result: String?
    public var target: String?
    public var source: String
    public var lastSequence: Int64?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String, provider: String, hostID: String, sessionID: String? = nil,
        project: String? = nil, parentTaskID: String? = nil, title: String,
        status: TaskStatus = .running, stage: String? = nil, message: String? = nil,
        progress: WorkProgress? = nil, result: String? = nil, target: String? = nil,
        source: String = "direct", lastSequence: Int64? = nil,
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.hostID = hostID
        self.sessionID = sessionID
        self.project = project
        self.parentTaskID = parentTaskID
        self.title = title
        self.status = status
        self.stage = stage
        self.message = message
        self.progress = progress
        self.result = result
        self.target = target
        self.source = source
        self.lastSequence = lastSequence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TaskPatch: Codable, Equatable, Sendable {
    public var status: TaskStatus?
    public var stage: String?
    public var message: String?
    public var progress: WorkProgress?
    public var result: String?
    public var target: String?

    public init(status: TaskStatus? = nil, stage: String? = nil, message: String? = nil,
                progress: WorkProgress? = nil, result: String? = nil, target: String? = nil) {
        self.status = status
        self.stage = stage
        self.message = message
        self.progress = progress
        self.result = result
        self.target = target
    }
}

public struct TaskEvent: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var taskID: String
    public var sequence: Int64?
    public var observedAt: Date
    public var source: String
    public var patch: TaskPatch
}

public enum CollectorState: String, Codable, Sendable { case active, paused }

public struct CollectorRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var taskID: String
    public var command: String
    public var workingDirectory: String?
    public var intervalSeconds: Double
    public var timeoutSeconds: Double
    public var state: CollectorState
    public var lastRunAt: Date?
    public var nextRunAt: Date
    public var lastSuccessAt: Date?
    public var lastError: String?

    public init(id: String, taskID: String, command: String, workingDirectory: String? = nil,
                intervalSeconds: Double = 30, timeoutSeconds: Double = 10,
                state: CollectorState = .active, lastRunAt: Date? = nil,
                nextRunAt: Date = Date(), lastSuccessAt: Date? = nil, lastError: String? = nil) {
        self.id = id
        self.taskID = taskID
        self.command = command
        self.workingDirectory = workingDirectory
        self.intervalSeconds = intervalSeconds
        self.timeoutSeconds = timeoutSeconds
        self.state = state
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt
        self.lastSuccessAt = lastSuccessAt
        self.lastError = lastError
    }
}

public struct CollectorOutput: Codable, Sendable {
    public var status: TaskStatus?
    public var stage: String?
    public var message: String?
    public var progress: WorkProgress?
    public var result: String?
    public var target: String?
    public var done: Bool?
}

public struct StateSnapshot: Codable, Sendable {
    public var tasks: [TaskRecord]
    public var collectors: [CollectorRecord]
    public var events: [TaskEvent]

    public init(tasks: [TaskRecord] = [], collectors: [CollectorRecord] = [], events: [TaskEvent] = []) {
        self.tasks = tasks
        self.collectors = collectors
        self.events = events
    }
}

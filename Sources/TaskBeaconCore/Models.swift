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

    public func currentPhaseStartedAt(in events: [TaskEvent]) -> Date {
        guard let currentStage = stage else { return createdAt }
        var observedStage: String?
        var startedAt = createdAt
        for event in events
            .filter({ $0.taskID == id && $0.observedAt >= createdAt })
            .sorted(by: { $0.observedAt < $1.observedAt }) {
            guard let eventStage = event.patch.stage, eventStage != observedStage else { continue }
            observedStage = eventStage
            if eventStage == currentStage { startedAt = event.observedAt }
        }
        return startedAt
    }

    public func currentPhaseDuration(in events: [TaskEvent], at now: Date = Date()) -> TimeInterval {
        let end = status.isTerminal ? updatedAt : now
        return max(0, end.timeIntervalSince(currentPhaseStartedAt(in: events)))
    }

    public func estimatedProgressRate(in events: [TaskEvent]) -> Double? {
        guard let current = progress, current.total > 0 else { return nil }
        let phaseStartedAt = currentPhaseStartedAt(in: events)
        let samples = events
            .filter {
                $0.taskID == id && $0.observedAt >= phaseStartedAt &&
                    $0.patch.progress?.total == current.total
            }
            .sorted(by: { $0.observedAt < $1.observedAt })
        guard let first = samples.first,
              let baseline = first.patch.progress,
              let last = samples.last,
              let latest = last.patch.progress else { return nil }
        let completedDelta = latest.completed - baseline.completed
        let elapsed = last.observedAt.timeIntervalSince(first.observedAt)
        guard completedDelta > 0, elapsed > 0 else { return nil }
        return completedDelta / elapsed
    }

    public func estimatedRemainingDuration(in events: [TaskEvent], at _: Date = Date()) -> TimeInterval? {
        guard !status.isTerminal, let current = progress, current.total > 0 else { return nil }
        let remaining = current.total - current.completed
        guard remaining > 0 else { return 0 }
        guard let rate = estimatedProgressRate(in: events) else { return nil }
        return remaining / rate
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
    /// Runtime-only state reported by the daemon. Optional for compatibility
    /// with snapshots written before this field existed.
    public var isRunning: Bool?

    public init(id: String, taskID: String, command: String, workingDirectory: String? = nil,
                intervalSeconds: Double = 30, timeoutSeconds: Double = 10,
                state: CollectorState = .active, lastRunAt: Date? = nil,
                nextRunAt: Date = Date(), lastSuccessAt: Date? = nil, lastError: String? = nil,
                isRunning: Bool? = nil) {
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
        self.isRunning = isRunning
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
    /// Keep scheduling this collector after it reports a terminal task status.
    /// Useful for long-lived monitors that can discover new work later.
    public var continuePolling: Bool?

    public var resolvedStatus: TaskStatus? {
        status ?? (done == true ? .completed : nil)
    }
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

import Foundation

public actor TaskStore {
    private var tasks: [String: TaskRecord] = [:]
    private var collectors: [String: CollectorRecord] = [:]
    private var activeCollectorRuns: [String: UUID] = [:]
    private var events: [TaskEvent] = []
    private var eventIDs: Set<String> = []
    private let fileURL: URL
    private var preparingForUpdate = false

    public init(fileURL: URL = RuntimePaths.stateFile) {
        self.fileURL = fileURL
    }

    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data = try Data(contentsOf: fileURL)
        let snapshot = try JSONCoding.decoder().decode(StateSnapshot.self, from: data)
        tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        collectors = Dictionary(uniqueKeysWithValues: snapshot.collectors.map { ($0.id, $0) })
        activeCollectorRuns.removeAll()
        events = snapshot.events
        eventIDs = Set(events.map(\.id))
    }

    @discardableResult
    public func register(_ task: TaskRecord) throws -> TaskRecord {
        try requireWritable()
        guard !task.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskBeaconError.invalid("task_id is required")
        }
        guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskBeaconError.invalid("title is required")
        }
        if let existing = tasks[task.id] { return existing }
        try validate(task.progress)
        tasks[task.id] = task
        try persist()
        return task
    }

    public func update(taskID: String, eventID: String, sequence: Int64?, observedAt: Date,
                       source: String, patch: TaskPatch) throws -> (TaskRecord, Bool) {
        try requireWritable()
        guard var task = tasks[taskID] else { throw TaskBeaconError.notFound("task not found: \(taskID)") }
        if eventIDs.contains(eventID) { return (task, true) }
        if let sequence, let last = task.lastSequence, sequence <= last { return (task, true) }
        if sequence == nil && observedAt < task.updatedAt { return (task, true) }
        try validate(patch.progress)

        if let value = patch.status { task.status = value }
        if let value = patch.stage { task.stage = value }
        if let value = patch.message { task.message = value }
        if let value = patch.progress { task.progress = value }
        if let value = patch.result { task.result = value }
        if let value = patch.target { task.target = value }
        task.source = source
        task.lastSequence = sequence ?? task.lastSequence
        task.updatedAt = observedAt
        tasks[taskID] = task

        let event = TaskEvent(id: eventID, taskID: taskID, sequence: sequence,
                              observedAt: observedAt, source: source, patch: patch)
        events.append(event)
        eventIDs.insert(eventID)
        if events.count > 10_000 {
            events.removeFirst(events.count - 10_000)
            eventIDs = Set(events.map(\.id))
        }
        try persist()
        return (task, false)
    }

    public func listTasks() -> [TaskRecord] {
        tasks.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Removes TaskBeacon's tracking data only. The underlying business task is never signalled.
    @discardableResult
    public func forgetTask(id: String) throws -> [UUID] {
        try requireWritable()
        guard let previousTask = tasks.removeValue(forKey: id) else {
            throw TaskBeaconError.notFound("task not found: \(id)")
        }

        let previousEvents = events
        let removedCollectors = collectors.filter { $0.value.taskID == id }
        let invalidatedRuns = removedCollectors.keys.reduce(into: [String: UUID]()) { result, collectorID in
            if let runID = activeCollectorRuns.removeValue(forKey: collectorID) {
                result[collectorID] = runID
            }
        }
        for collectorID in removedCollectors.keys {
            collectors.removeValue(forKey: collectorID)
        }
        events.removeAll { $0.taskID == id }
        eventIDs = Set(events.map(\.id))

        do {
            try persist()
        } catch {
            tasks[id] = previousTask
            collectors.merge(removedCollectors) { current, _ in current }
            events = previousEvents
            eventIDs = Set(events.map(\.id))
            for (collectorID, runID) in invalidatedRuns {
                activeCollectorRuns[collectorID] = runID
            }
            throw error
        }
        return Array(invalidatedRuns.values)
    }

    public func registerCollector(_ collector: CollectorRecord) throws -> CollectorRecord {
        try registerCollectorAndInvalidate(collector).collector
    }

    public func registerCollectorAndInvalidate(
        _ collector: CollectorRecord
    ) throws -> (collector: CollectorRecord, invalidatedRunID: UUID?) {
        try requireWritable()
        guard tasks[collector.taskID] != nil else {
            throw TaskBeaconError.notFound("task not found: \(collector.taskID)")
        }
        guard collector.intervalSeconds >= 1 else {
            throw TaskBeaconError.invalid("collector interval must be at least 1 second")
        }
        guard collector.timeoutSeconds > 0 else {
            throw TaskBeaconError.invalid("collector timeout must be positive")
        }
        guard !collector.command.isEmpty else {
            throw TaskBeaconError.invalid("collector command is required")
        }

        let previousCollector = collectors[collector.id]
        let invalidatedRunID = activeCollectorRuns.removeValue(forKey: collector.id)
        collectors[collector.id] = collector
        do {
            try persist()
        } catch {
            if let previousCollector {
                collectors[collector.id] = previousCollector
            } else {
                collectors.removeValue(forKey: collector.id)
            }
            if let invalidatedRunID {
                activeCollectorRuns[collector.id] = invalidatedRunID
            }
            throw error
        }
        return (collector, invalidatedRunID)
    }

    public func setCollectorState(id: String, state: CollectorState) throws -> CollectorRecord {
        try setCollectorStateAndInvalidate(id: id, state: state).collector
    }

    public func setCollectorStateAndInvalidate(
        id: String, state: CollectorState
    ) throws -> (collector: CollectorRecord, invalidatedRunID: UUID?) {
        try requireWritable()
        guard let previousCollector = collectors[id] else {
            throw TaskBeaconError.notFound("collector not found: \(id)")
        }
        var collector = previousCollector
        let previousRunID = activeCollectorRuns[id]
        collector.state = state
        if state == .active {
            collector.nextRunAt = Date()
        } else {
            activeCollectorRuns.removeValue(forKey: id)
        }
        collectors[id] = collector
        do {
            try persist()
        } catch {
            collectors[id] = previousCollector
            if let previousRunID {
                activeCollectorRuns[id] = previousRunID
            } else {
                activeCollectorRuns.removeValue(forKey: id)
            }
            throw error
        }
        return (collector, state == .paused ? previousRunID : nil)
    }

    public func removeCollector(id: String) throws {
        _ = try removeCollectorAndInvalidate(id: id)
    }

    public func removeCollectorAndInvalidate(id: String) throws -> UUID? {
        try requireWritable()
        guard let previousCollector = collectors.removeValue(forKey: id) else {
            throw TaskBeaconError.notFound("collector not found: \(id)")
        }
        let invalidatedRunID = activeCollectorRuns.removeValue(forKey: id)
        do {
            try persist()
        } catch {
            collectors[id] = previousCollector
            if let invalidatedRunID {
                activeCollectorRuns[id] = invalidatedRunID
            }
            throw error
        }
        return invalidatedRunID
    }

    public func listCollectors() -> [CollectorRecord] {
        collectors.values.map { stored in
            var collector = stored
            collector.isRunning = activeCollectorRuns[collector.id] != nil
            return collector
        }.sorted { $0.id < $1.id }
    }

    public func requestCollectorRun(id: String, at date: Date = Date()) throws -> CollectorRecord {
        try requireWritable()
        guard var collector = collectors[id] else {
            throw TaskBeaconError.notFound("collector not found: \(id)")
        }
        guard collector.state == .active else {
            throw TaskBeaconError.invalid("collector is paused: \(id)")
        }
        let previousCollector = collector
        collector.nextRunAt = date
        collectors[id] = collector
        do {
            try persist()
        } catch {
            collectors[id] = previousCollector
            throw error
        }
        return collector
    }

    public func dueCollectors(at date: Date = Date()) -> [CollectorRecord] {
        guard !preparingForUpdate else { return [] }
        return collectors.values.filter {
            $0.state == .active && $0.nextRunAt <= date && activeCollectorRuns[$0.id] == nil
        }
    }

    @discardableResult
    public func markCollectorStarted(id: String, at date: Date = Date()) throws -> UUID? {
        let runID = UUID()
        return try claimCollectorRun(id: id, runID: runID, at: date) == nil ? nil : runID
    }

    /// Atomically claims the current collector configuration and returns the exact record to run.
    /// Returning the record avoids launching a stale scheduler snapshot after replacement.
    public func claimCollectorRun(
        id: String, runID: UUID, at date: Date = Date()
    ) throws -> CollectorRecord? {
        try requireWritable()
        guard var collector = collectors[id], collector.state == .active,
              collector.nextRunAt <= date, activeCollectorRuns[id] == nil else { return nil }
        let previousCollector = collector
        activeCollectorRuns[id] = runID
        collector.lastRunAt = date
        collector.nextRunAt = date.addingTimeInterval(collector.intervalSeconds)
        collectors[id] = collector
        do {
            try persist()
        } catch {
            collectors[id] = previousCollector
            activeCollectorRuns.removeValue(forKey: id)
            throw error
        }
        return collector
    }

    public func isCollectorRunCurrent(id: String, runID: UUID) -> Bool {
        activeCollectorRuns[id] == runID && collectors[id]?.state == .active
    }

    @discardableResult
    public func completeCollectorRun(id: String, runID: UUID, patch: TaskPatch,
                                     at date: Date = Date()) throws -> Bool {
        try requireWritable()
        guard activeCollectorRuns[id] == runID, var collector = collectors[id],
              collector.state == .active else { return false }

        _ = try update(taskID: collector.taskID, eventID: UUID().uuidString,
                       sequence: nil, observedAt: date, source: "collector:\(collector.id)", patch: patch)
        activeCollectorRuns.removeValue(forKey: id)
        collector.lastSuccessAt = date
        collector.lastError = nil
        collector.nextRunAt = date.addingTimeInterval(collector.intervalSeconds)
        if patch.status?.isTerminal == true { collector.state = .paused }
        collectors[id] = collector
        try persist()
        return true
    }

    @discardableResult
    public func failCollectorRun(id: String, runID: UUID, error: String,
                                 at date: Date = Date()) throws -> Bool {
        try requireWritable()
        guard activeCollectorRuns[id] == runID else { return false }
        activeCollectorRuns.removeValue(forKey: id)
        guard var collector = collectors[id], collector.state == .active else { return false }
        collector.lastError = error
        collector.nextRunAt = date.addingTimeInterval(collector.intervalSeconds)
        collectors[id] = collector
        try persist()
        return true
    }

    public func recordCollectorRun(id: String, success: Bool, error: String?, at date: Date = Date()) throws {
        try requireWritable()
        guard var collector = collectors[id] else { return }
        if success {
            collector.lastSuccessAt = date
            collector.lastError = nil
        } else {
            collector.lastError = error
        }
        collectors[id] = collector
        try persist()
    }

    public func snapshot() -> StateSnapshot {
        StateSnapshot(tasks: listTasks(), collectors: listCollectors(), events: events)
    }

    /// Finish acknowledged writes before the old process hands its state to the updated daemon.
    public func prepareForUpdate() throws {
        try requireWritable()
        try persist()
        preparingForUpdate = true
    }

    private func requireWritable() throws {
        guard !preparingForUpdate else {
            throw TaskBeaconError.connection("TaskBeacon is restarting for an update; retry shortly")
        }
    }

    private func validate(_ progress: WorkProgress?) throws {
        guard let progress else { return }
        guard progress.total > 0, progress.completed >= 0, progress.completed <= progress.total else {
            throw TaskBeaconError.invalid("progress requires 0 <= completed <= total and total > 0")
        }
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONCoding.encoder(pretty: true).encode(snapshot())
        let temporary = directory.appendingPathComponent(".state-\(UUID().uuidString).json")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        }
    }
}

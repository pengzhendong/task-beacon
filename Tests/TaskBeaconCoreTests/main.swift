import Foundation
import TaskBeaconCore

@main
struct TaskBeaconSelfTest {
    static func main() async {
        do {
            try await deduplicatesEventsAndRejectsOldSequence()
            try await rejectsStaleObservedTime()
            try await persistsCollectorHealthSeparately()
            try await rejectsInvalidProgress()
            try await preventsOverlappingCollectorRuns()
            try await discardsResultsFromReplacedCollectors()
            try await keepsCurrentRunWhenReplacementIsInvalid()
            try await rollsBackCollectorClaimWhenPersistenceFails()
            try await forgetsOnlyTrackingData()
            try await sealsStateDuringUpdateHandoff()
            try await handsOffOnlyItsOwnDaemon()
            print("TaskBeacon self-test passed (11/11)")
        } catch {
            FileHandle.standardError.write(Data("TaskBeacon self-test failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func rejectsStaleObservedTime() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = TaskRecord(id: "stale-task", provider: "test", hostID: "host", title: "Test")
        _ = try await store.register(task)
        let result = try await store.update(
            taskID: task.id, eventID: "stale-event", sequence: nil,
            observedAt: Date(timeIntervalSince1970: 0), source: "test",
            patch: TaskPatch(stage: "stale")
        )
        try require(result.1, "stale observed_at was accepted")
        try require(result.0.stage == nil, "stale event changed task state")
    }

    private static func makeStore() -> (TaskStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskbeacon-tests-\(UUID().uuidString)", isDirectory: true)
        return (TaskStore(fileURL: directory.appendingPathComponent("state.json")), directory)
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TaskBeaconError.invalid(message) }
    }

    private static func deduplicatesEventsAndRejectsOldSequence() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = TaskRecord(id: "task-1", provider: "test", hostID: "host", title: "Test")
        _ = try await store.register(task)

        let first = try await store.update(
            taskID: "task-1", eventID: "event-1", sequence: 2,
            observedAt: Date(), source: "test",
            patch: TaskPatch(stage: "running", progress: WorkProgress(completed: 2, total: 10))
        )
        try require(!first.1, "first event was ignored")

        let duplicate = try await store.update(
            taskID: "task-1", eventID: "event-1", sequence: 2,
            observedAt: Date(), source: "test", patch: TaskPatch(stage: "wrong")
        )
        try require(duplicate.1, "duplicate event was accepted")

        let old = try await store.update(
            taskID: "task-1", eventID: "event-2", sequence: 1,
            observedAt: Date(), source: "test", patch: TaskPatch(stage: "also wrong")
        )
        try require(old.1, "out-of-order event was accepted")
        let tasks = await store.listTasks()
        try require(tasks.first?.stage == "running", "ignored event changed the stage")
        try require(tasks.first?.progress == WorkProgress(completed: 2, total: 10), "progress was not saved")
    }

    private static func persistsCollectorHealthSeparately() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = TaskRecord(id: "task-2", provider: "test", hostID: "host", title: "Long job")
        _ = try await store.register(task)
        let collector = CollectorRecord(
            id: "collector-1", taskID: "task-2", command: "echo '{}'", intervalSeconds: 5
        )
        _ = try await store.registerCollector(collector)
        try await store.recordCollectorRun(id: "collector-1", success: false, error: "timeout")

        let restored = TaskStore(fileURL: directory.appendingPathComponent("state.json"))
        try await restored.load()
        let restoredTask = await restored.listTasks().first
        let restoredCollector = await restored.listCollectors().first
        try require(restoredTask?.status == .running, "collector failure changed business status")
        try require(restoredCollector?.lastError == "timeout", "collector health was not restored")
    }

    private static func rejectsInvalidProgress() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = TaskRecord(id: "task-3", provider: "test", hostID: "host", title: "Test")
        _ = try await store.register(task)
        var rejected = false
        do {
            _ = try await store.update(
                taskID: "task-3", eventID: "event-1", sequence: nil,
                observedAt: Date(), source: "test",
                patch: TaskPatch(progress: WorkProgress(completed: 11, total: 10))
            )
        } catch {
            rejected = error.localizedDescription.contains("progress")
        }
        try require(rejected, "invalid progress was accepted")
    }

    private static func preventsOverlappingCollectorRuns() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = TaskRecord(id: "single-flight-task", provider: "test", hostID: "host", title: "Test")
        _ = try await store.register(task)
        _ = try await store.registerCollector(CollectorRecord(
            id: "single-flight", taskID: task.id, command: "echo '{}'", intervalSeconds: 5
        ))

        let startedAt = Date()
        let firstRun = try await store.markCollectorStarted(id: "single-flight", at: startedAt)
        try require(firstRun != nil, "first collector run did not start")
        let dueWhileRunning = await store.dueCollectors(at: startedAt.addingTimeInterval(60))
        try require(dueWhileRunning.isEmpty, "collector became due while its previous run was active")
        let overlappingRun = try await store.markCollectorStarted(
            id: "single-flight", at: startedAt.addingTimeInterval(60)
        )
        try require(overlappingRun == nil, "overlapping collector run was accepted")

        let finishedAt = startedAt.addingTimeInterval(10)
        _ = try await store.completeCollectorRun(
            id: "single-flight", runID: firstRun!, patch: TaskPatch(stage: "done"), at: finishedAt
        )
        let tooEarly = await store.dueCollectors(at: finishedAt.addingTimeInterval(4))
        let nextDue = await store.dueCollectors(at: finishedAt.addingTimeInterval(5))
        try require(tooEarly.isEmpty, "collector interval was measured from start instead of completion")
        try require(nextDue.map(\.id) == ["single-flight"], "collector was not rescheduled after completion")
    }

    private static func discardsResultsFromReplacedCollectors() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = TaskRecord(id: "replacement-task", provider: "test", hostID: "host", title: "Test")
        _ = try await store.register(task)
        _ = try await store.registerCollector(CollectorRecord(
            id: "replace-me", taskID: task.id, command: "echo old"
        ))
        let oldRun = try await store.markCollectorStarted(id: "replace-me")
        try require(oldRun != nil, "old collector run did not start")

        _ = try await store.registerCollector(CollectorRecord(
            id: "replace-me", taskID: task.id, command: "echo new"
        ))
        let accepted = try await store.completeCollectorRun(
            id: "replace-me", runID: oldRun!, patch: TaskPatch(stage: "stale")
        )
        try require(!accepted, "replaced collector result was accepted")
        let restoredTask = await store.listTasks().first
        let replacement = await store.listCollectors().first
        try require(restoredTask?.stage == nil, "replaced collector changed the task")
        try require(replacement?.command == "echo new" && replacement?.lastSuccessAt == nil,
                    "replaced collector changed the replacement health")

        let replacementRunID = UUID()
        let claimed = try await store.claimCollectorRun(
            id: "replace-me", runID: replacementRunID, at: Date().addingTimeInterval(1)
        )
        try require(claimed?.command == "echo new", "scheduler claimed a stale collector configuration")
    }

    private static func keepsCurrentRunWhenReplacementIsInvalid() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = TaskRecord(id: "invalid-replacement-task", provider: "test", hostID: "host", title: "Test")
        _ = try await store.register(task)
        _ = try await store.registerCollector(CollectorRecord(
            id: "invalid-replacement", taskID: task.id, command: "echo old"
        ))
        let currentRun = try await store.markCollectorStarted(id: "invalid-replacement")
        try require(currentRun != nil, "collector run did not start")

        var rejected = false
        do {
            _ = try await store.registerCollectorAndInvalidate(CollectorRecord(
                id: "invalid-replacement", taskID: task.id, command: "echo invalid", intervalSeconds: 0
            ))
        } catch {
            rejected = true
        }
        try require(rejected, "invalid replacement was accepted")
        let isCurrent = await store.isCollectorRunCurrent(
            id: "invalid-replacement", runID: currentRun!
        )
        try require(
            isCurrent,
            "invalid replacement cancelled the current healthy run"
        )
    }

    private static func rollsBackCollectorClaimWhenPersistenceFails() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = TaskRecord(id: "claim-rollback-task", provider: "test", hostID: "host", title: "Test")
        _ = try await store.register(task)
        _ = try await store.registerCollector(CollectorRecord(
            id: "claim-rollback", taskID: task.id, command: "echo '{}'"
        ))

        try FileManager.default.removeItem(at: directory)
        try Data("not a directory".utf8).write(to: directory)
        var failed = false
        do {
            _ = try await store.claimCollectorRun(
                id: "claim-rollback", runID: UUID(), at: Date().addingTimeInterval(1)
            )
        } catch {
            failed = true
        }
        try require(failed, "collector claim unexpectedly persisted to an invalid state path")

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let retriedRunID = UUID()
        let retried = try await store.claimCollectorRun(
            id: "claim-rollback", runID: retriedRunID, at: Date().addingTimeInterval(2)
        )
        try require(retried != nil, "failed persistence left the collector permanently claimed")
    }

    private static func forgetsOnlyTrackingData() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = TaskRecord(id: "forgotten-task", provider: "test", hostID: "host", title: "Keep running")
        _ = try await store.register(task)
        _ = try await store.update(
            taskID: task.id, eventID: "forgotten-event", sequence: 1,
            observedAt: Date(), source: "test", patch: TaskPatch(stage: "Working")
        )
        _ = try await store.registerCollector(CollectorRecord(
            id: "forgotten-collector", taskID: task.id, command: "echo '{}'"
        ))
        let runID = try await store.markCollectorStarted(id: "forgotten-collector")
        try require(runID != nil, "collector run did not start")

        let invalidatedRunIDs = try await store.forgetTask(id: task.id)
        let snapshot = await store.snapshot()
        try require(invalidatedRunIDs == [runID!], "active collector run was not invalidated")
        try require(snapshot.tasks.isEmpty, "forgotten task remained visible")
        try require(snapshot.collectors.isEmpty, "forgotten task's collector remained registered")
        try require(snapshot.events.isEmpty, "forgotten task's event history remained stored")
    }

    private static func sealsStateDuringUpdateHandoff() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = TaskRecord(id: "handoff-task", provider: "test", hostID: "host", title: "Still working")
        _ = try await store.register(task)
        _ = try await store.registerCollector(CollectorRecord(
            id: "handoff-collector", taskID: task.id, command: "echo '{}'", intervalSeconds: 5
        ))
        try await store.prepareForUpdate()
        let due = await store.dueCollectors()
        try require(due.isEmpty, "new collectors started while handing off state")
        var rejected = false
        do {
            _ = try await store.update(taskID: task.id, eventID: "late-result", sequence: nil,
                                       observedAt: Date(), source: "collector", patch: TaskPatch(stage: "late"))
        } catch { rejected = true }
        try require(rejected, "late collector wrote to the old store after handoff")

        let restored = TaskStore(fileURL: directory.appendingPathComponent("state.json"))
        try await restored.load()
        let snapshot = await restored.snapshot()
        try require(snapshot.tasks.first?.stage == nil, "late result leaked into restored state")
        try require(snapshot.collectors.first?.state == .active, "handoff changed collector configuration")
        _ = try await restored.update(taskID: task.id, eventID: "new-result", sequence: nil,
                                      observedAt: Date(), source: "test", patch: TaskPatch(stage: "resumed"))
    }

    private static func handsOffOnlyItsOwnDaemon() async throws {
        let daemonURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent().appendingPathComponent("taskbeacond")
        guard FileManager.default.isExecutableFile(atPath: daemonURL.path) else {
            throw TaskBeaconError.invalid("run swift build before self-test to build the daemon integration fixture")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskbeacon-handoff-\(UUID().uuidString)", isDirectory: true)
        let socketPath = "/tmp/tb-handoff-\(UUID().uuidString).sock"
        let client = TaskBeaconClient(socketPath: socketPath, timeout: 5)
        var processes: [Process] = []
        defer {
            for process in processes where process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        func launch() throws -> Process {
            let process = Process()
            process.executableURL = daemonURL
            var environment = ProcessInfo.processInfo.environment
            environment["TASKBEACON_DATA_DIR"] = directory.path
            environment["TASKBEACON_SOCKET"] = socketPath
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            processes.append(process)
            return process
        }
        func waitUntilReady() async throws {
            for _ in 0..<100 {
                if (try? client.send(WireRequest(action: "ping")))?.ok == true { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw TaskBeaconError.connection("isolated daemon did not become ready")
        }
        let first = try launch()
        try await waitUntilReady()
        let wrongInstallation = try client.send(WireRequest(
            action: "service.prepare-update", expectedExecutablePath: daemonURL.path + ".other"
        ))
        try require(!wrongInstallation.ok && first.isRunning, "update stopped a different installation")
        let task = TaskRecord(id: "live-task", provider: "test", hostID: "host", title: "Persist me",
                              progress: WorkProgress(completed: 3, total: 10))
        try require(try client.send(WireRequest(action: "register", task: task)).ok, "task registration failed")
        let collector = CollectorRecord(id: "live-collector", taskID: task.id,
                                         command: "exec /bin/sleep 30", intervalSeconds: 3600, timeoutSeconds: 60)
        try require(try client.send(WireRequest(action: "collector.register", collector: collector)).ok,
                    "collector registration failed")
        var collectorStarted = false
        for _ in 0..<60 {
            let snapshot = try client.send(WireRequest(action: "snapshot")).snapshot
            if snapshot?.collectors.first?.lastRunAt != nil { collectorStarted = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(collectorStarted, "collector fixture did not start")
        try await Task.sleep(for: .milliseconds(100))
        let handoff = try client.send(WireRequest(action: "service.prepare-update", expectedExecutablePath: daemonURL.path))
        try require(handoff.ok, "daemon did not acknowledge handoff")
        for _ in 0..<60 where first.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        try require(!first.isRunning && first.terminationStatus == 0, "old daemon did not exit cleanly")
        let second = try launch()
        try await waitUntilReady()
        try require(second.processIdentifier != first.processIdentifier, "daemon was not replaced")
        let restored = try client.send(WireRequest(action: "snapshot")).snapshot
        try require(restored?.tasks.first?.progress == task.progress, "update lost task progress")
        try require(restored?.collectors.first?.state == .active, "update lost active collector configuration")
        try require(restored?.collectors.first?.lastError == nil, "update cancellation became a collector failure")

        let forgotten = try client.send(WireRequest(action: "task.forget", taskID: task.id))
        try require(forgotten.ok, "daemon refused to forget a tracked task")
        let afterForget = try client.send(WireRequest(action: "snapshot")).snapshot
        try require(afterForget?.tasks.isEmpty == true, "forgotten task remained in daemon state")
        try require(afterForget?.collectors.isEmpty == true, "forgotten task's collector remained in daemon state")
    }
}

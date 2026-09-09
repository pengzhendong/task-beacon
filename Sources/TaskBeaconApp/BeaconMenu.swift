import SwiftUI
import AppKit
import TaskBeaconCore

struct BeaconMenu: View {
    @ObservedObject var model: BeaconModel
    @ObservedObject var updater: UpdateController
    @Binding var expandedTaskID: String?
    @Binding var isPinned: Bool
    @State private var installerNotice: InstallerNotice?
    @State private var taskListContentHeight: CGFloat = 1

    private let maxTaskListHeight: CGFloat = 430

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = model.connectionError {
                EmptyState(title: "服务未连接", systemImage: "bolt.slash", detail: error)
                    .frame(height: 140)
            } else if model.tasks.isEmpty {
                EmptyState(title: "暂无任务", systemImage: "checkmark.circle",
                           detail: "通过 CLI 或 MCP 注册任务后会显示在这里")
                    .frame(height: 140)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
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
                                    TaskRow(
                                        task: task,
                                        collector: collector(for: task.id),
                                        phaseStartedAt: task.currentPhaseStartedAt(in: model.events),
                                        estimatedRemaining: task.estimatedRemainingDuration(in: model.events),
                                        estimatedRate: task.estimatedProgressRate(in: model.events),
                                        isRefreshing: collector(for: task.id).map {
                                            model.refreshingCollectorIDs.contains($0.id)
                                        } ?? false,
                                        confirmingForget: Binding(
                                            get: { expandedTaskID == task.id },
                                            set: { expandedTaskID = $0 ? task.id : nil }
                                        ),
                                        onRefresh: { await refresh(task) },
                                        onForget: { forget(task) }
                                    )
                                }
                            }
                        }
                    }
                    .padding(12)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: TaskListHeightPreferenceKey.self,
                                value: geometry.size.height
                            )
                        }
                    }
                }
                .frame(height: min(taskListContentHeight, maxTaskListHeight))
                .onPreferenceChange(TaskListHeightPreferenceKey.self) { height in
                    taskListContentHeight = max(1, height)
                }
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.3))
            }
            footer
        }
        .alert(item: $installerNotice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message),
                  dismissButton: .default(Text("好")))
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(BeaconPalette.sage).frame(width: 7, height: 7)
            Text("\(model.activeCount) 个进行中")
                .font(.subheadline.weight(.medium))
            if model.attentionCount > 0 {
                Text("· \(model.attentionCount) 个需处理")
                    .font(.subheadline)
                    .foregroundStyle(BeaconPalette.amber)
            }
            Spacer()
            Button { isPinned.toggle() } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isPinned ? BeaconPalette.sage : Color.primary)
            .background(Color.primary.opacity(0.055), in: Circle())
            .help(isPinned ? "取消固定" : "固定窗口")
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .background(Color.primary.opacity(0.055), in: Circle())
            .help("刷新界面")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button { updater.checkForUpdates() } label: {
                Label(updater.statusText, systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.plain)
            .disabled(updater.isChecking)
            Spacer()
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

    private func forget(_ task: TaskRecord) {
        expandedTaskID = nil
        Task {
            if let error = await model.forgetTask(id: task.id) {
                installerNotice = InstallerNotice(title: "停止跟踪失败", message: error)
            }
        }
    }

    private func refresh(_ task: TaskRecord) async {
        if let collector = collector(for: task.id) {
            if let error = await model.runCollector(id: collector.id) {
                installerNotice = InstallerNotice(title: "立即刷新失败", message: error)
            }
        } else {
            await model.refresh()
        }
    }

    private var groups: [(key: String, value: [TaskRecord])] {
        Dictionary(grouping: model.tasks) { task in
            task.project ?? "未分组"
        }.map { group in
            let key = group.key.isEmpty ? "未分组" : group.key
            let tasks = group.value.sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
            }
            return (key: key, value: tasks)
        }
        .sorted { $0.key < $1.key }
    }

    private func collector(for taskID: String) -> CollectorRecord? {
        model.collectors.first { $0.taskID == taskID }
    }

}

private struct TaskListHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 1

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct InstallerNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum BeaconPalette {
    // Radix Colors: quiet Sage neutrals with semantic Grass, Amber and Tomato.
    // Keep the progress fill deliberately lighter than the status foreground.
    static let sage = adaptive(light: 0x2A7E3B, dark: 0x71D083)       // Grass 11
    static let progressSage = adaptive(light: 0x94CE9A, dark: 0x53B365) // Grass 7 / 10
    static let amber = adaptive(light: 0xAB6400, dark: 0xFFCA16)      // Amber 11
    static let tomato = adaptive(light: 0xD13415, dark: 0xFF977D)     // Tomato 11
    static let completed = adaptive(light: 0x7C8481, dark: 0x717D79)  // Sage 10

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
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
    let phaseStartedAt: Date
    let estimatedRemaining: TimeInterval?
    let estimatedRate: Double?
    let isRefreshing: Bool
    @Binding var confirmingForget: Bool
    let onRefresh: () async -> Void
    let onForget: () -> Void
    @State private var messageExpanded = false
    @State private var isManualRefreshing = false

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
                Text(statusText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.12), in: Capsule())
                if task.status != .completed,
                   let target = task.target,
                   let url = targetURL(target) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .help("打开结果")
                }
            }
            if task.stage != nil || task.message != nil {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let stage = task.stage {
                        Text(stage).fontWeight(.medium).foregroundStyle(.primary)
                    }
                    if task.stage != nil, task.message != nil {
                        Text("·").foregroundStyle(.tertiary)
                    }
                    if let message = task.message {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .lineLimit(messageExpanded ? nil : 1)
                    }
                    if messageNeedsExpansion {
                        Spacer(minLength: 2)
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                messageExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: messageExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(messageExpanded ? "收起详情" : "展开详情")
                    }
                }
                .font(.caption)
            }
            if let progress = task.progress, let fraction = progress.fraction {
                VStack(spacing: 3) {
                    HStack(spacing: 7) {
                        Text(percentText(fraction))
                            .fontWeight(.medium)
                            .fixedSize()
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.primary.opacity(0.10))
                                Capsule()
                                    .fill(progressColor)
                                    .frame(width: geometry.size.width * fraction)
                            }
                        }
                        .frame(height: 5)
                        .accessibilityElement()
                        .accessibilityLabel("任务进度")
                        .accessibilityValue(percentText(fraction))
                        Text(progressText(progress))
                            .fixedSize()
                    }
                    metadataRow(progress: progress)
                }
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            if let error = collector?.lastError {
                Label("采集异常：\(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(BeaconPalette.amber)
                    .lineLimit(1)
            }
            if task.progress == nil {
                metadataRow(progress: nil)
            }
            if confirmingForget {
                Divider()
                HStack(spacing: 8) {
                    Label("不会终止实际任务", systemImage: "eye.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("停止跟踪", role: .destructive, action: onForget)
                }
                .controlSize(.small)
                .offset(y: -2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 11)
        .padding(.top, 11)
        .padding(.bottom, 4)
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
        case .running: BeaconPalette.sage
        case .waiting: BeaconPalette.amber
        case .failed: BeaconPalette.tomato
        case .cancelled: .secondary
        case .completed: BeaconPalette.completed
        }
    }

    private var progressColor: Color {
        task.status == .running ? BeaconPalette.progressSage : color
    }

    private var messageNeedsExpansion: Bool {
        guard let message = task.message else { return false }
        if message.contains("\n") { return true }
        let messageWidth = message.unicodeScalars.reduce(0) { width, scalar in
            width + (scalar.isASCII ? 1 : 2)
        }
        let stageWidth = task.stage?.unicodeScalars.reduce(0) { width, scalar in
            width + (scalar.isASCII ? 1 : 2)
        } ?? 0
        return messageWidth + stageWidth > 54
    }

    private func display(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func progressText(_ progress: WorkProgress) -> String {
        "\(display(progress.completed))/\(display(progress.total))"
    }

    private func percentText(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }

    private func metadataRow(progress: WorkProgress?) -> some View {
        HStack(spacing: 5) {
            if let progress {
                timingSummary(progress)
                    .font(.system(size: 9.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .layoutPriority(1)
            }
            Spacer(minLength: 4)
            Text(collector.map { refreshStatusText(for: $0) } ?? lastUpdatedText)
                .monospacedDigit()
                .fixedSize()
                .foregroundStyle(collector.map { refreshStatusColor(for: $0) } ?? Color.secondary)
                .help(collector.map { lastSuccessfulUpdateHelp(for: $0) } ?? "上次收到进度：\(task.updatedAt.formatted())")
            Button {
                Task {
                    isManualRefreshing = true
                    await onRefresh()
                    isManualRefreshing = false
                }
            } label: {
                if isRefreshing || isManualRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .disabled(
                isRefreshing || isManualRefreshing ||
                    collector.map { collectorIsRunning($0) || $0.state != .active } == true
            )
            .help(
                collector.map { "立即运行采集器\n\(lastSuccessfulUpdateHelp(for: $0))" }
                    ?? "重新读取本地最新进度"
            )
            moreButton
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var moreButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                confirmingForget.toggle()
            }
        } label: {
            Image(systemName: confirmingForget ? "xmark" : "ellipsis")
                .font(.caption2.weight(.semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(confirmingForget ? "收起操作" : "更多操作")
    }

    @ViewBuilder
    private func timingSummary(_ progress: WorkProgress) -> some View {
        let elapsedEnd = task.status.isTerminal ? task.updatedAt : Date()
        let elapsed = max(0, elapsedEnd.timeIntervalSince(phaseStartedAt))
        HStack(spacing: 5) {
            Text(task.status.isTerminal ? "耗时 \(clockDuration(elapsed))" : "已用 \(clockDuration(elapsed))")
                .monospacedDigit()
            timingSeparator
            if task.status == .completed {
                Text("已完成").foregroundStyle(color)
            } else if task.status.isTerminal {
                Text("已停止").foregroundStyle(color)
            } else if let estimatedRemaining {
                Text("剩余约 \(clockDuration(estimatedRemaining))")
                    .monospacedDigit()
            } else {
                Text("正在估算剩余时间和速度")
            }
            if let estimatedRate {
                timingSeparator
                Text(rateText(estimatedRate, progress: progress))
                    .monospacedDigit()
            }
        }
    }

    private var timingSeparator: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    private func rateText(_ rate: Double, progress: WorkProgress) -> String {
        let value: String
        if rate >= 100 {
            value = String(format: "%.0f", rate)
        } else if rate >= 10 {
            value = String(format: "%.1f", rate)
        } else {
            value = String(format: "%.2f", rate)
        }
        return "\(value) \(localizedUnit(progress.unit))/秒"
    }

    private func localizedUnit(_ unit: String?) -> String {
        switch unit?.lowercased() {
        case "step", "steps": "步"
        case "file", "files": "文件"
        case "shard", "shards": "分片"
        case "batch", "batches": "批"
        case "percent", "%": "%"
        case let value?: value
        case nil: "项"
        }
    }

    private func clockDuration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        let days = seconds / 86_400
        let hours = seconds % 86_400 / 3_600
        let minutes = seconds % 3_600 / 60
        let remainder = seconds % 60
        if days > 0 { return String(format: "%dd%02d:%02d:%02d", days, hours, minutes, remainder) }
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainder) }
        return String(format: "%02d:%02d", minutes, remainder)
    }

    private var lastUpdatedText: String {
        let seconds = max(0, Int(Date().timeIntervalSince(task.updatedAt)))
        if seconds < 2 { return "刚刚更新" }
        if seconds < 60 { return "\(seconds)秒前更新" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)分前更新" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)小时前更新" }
        return "\(hours / 24)天前更新"
    }

    private func nextRefreshText(for collector: CollectorRecord) -> String {
        if collector.state == .paused { return "已暂停" }
        if isRefreshing || collectorIsRunning(collector) { return "刷新中" }
        let seconds = Int(ceil(collector.nextRunAt.timeIntervalSinceNow))
        if seconds <= 0 { return "即将刷新" }
        if seconds < 60 { return "\(seconds)秒后刷新" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)分后刷新" }
        return "\(minutes / 60)小时后刷新"
    }

    private func refreshStatusText(for collector: CollectorRecord) -> String {
        if collector.state == .paused { return "已暂停" }
        if isRefreshing || collectorIsRunning(collector) { return "刷新中" }
        guard let lastSuccessAt = collector.lastSuccessAt else { return "等待首次刷新" }
        if collectorIsStale(collector) {
            return "\(shortAge(Date().timeIntervalSince(lastSuccessAt)))未更新"
        }
        return nextRefreshText(for: collector)
    }

    private func refreshStatusColor(for collector: CollectorRecord) -> Color {
        collectorIsStale(collector) ? BeaconPalette.amber : .secondary
    }

    private func collectorIsStale(_ collector: CollectorRecord) -> Bool {
        guard collector.state == .active,
              !isRefreshing,
              !collectorIsRunning(collector),
              let lastSuccessAt = collector.lastSuccessAt else { return false }
        let tolerance = max(collector.intervalSeconds * 2, collector.intervalSeconds + collector.timeoutSeconds)
        return Date().timeIntervalSince(lastSuccessAt) > tolerance
    }

    private func shortAge(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)分" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)小时" }
        return "\(hours / 24)天"
    }

    private func lastSuccessfulUpdateHelp(for collector: CollectorRecord) -> String {
        guard let date = collector.lastSuccessAt else { return "尚未成功刷新" }
        return "最后成功更新：\(date.formatted(date: .abbreviated, time: .standard))"
    }

    private func collectorIsRunning(_ collector: CollectorRecord) -> Bool {
        guard collector.lastError == nil, let lastRunAt = collector.lastRunAt else { return false }
        guard let lastSuccessAt = collector.lastSuccessAt else { return true }
        return lastRunAt > lastSuccessAt
    }

    private func targetURL(_ target: String) -> URL? {
        if target.hasPrefix("/") { return URL(fileURLWithPath: target) }
        return URL(string: target)
    }
}

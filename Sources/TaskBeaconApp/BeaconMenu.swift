import SwiftUI
import AppKit
import TaskBeaconCore

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
        HStack(spacing: 6) {
            Circle().fill(brandGreen).frame(width: 7, height: 7)
            Text("\(model.activeCount) 个进行中")
                .font(.subheadline.weight(.medium))
            if model.attentionCount > 0 {
                Text("· \(model.attentionCount) 个需处理")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
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
        .padding(.vertical, 9)
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

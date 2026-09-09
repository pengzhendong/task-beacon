import SwiftUI
import AppKit
import TaskBeaconCore

struct BeaconMenu: View {
    @ObservedObject var model: BeaconModel
    @ObservedObject var updater: UpdateController
    @Binding var expandedTaskID: String?
    @State private var commandLineToolsInstalled = CommandLineInstaller.isInstalled
    @State private var installerNotice: InstallerNotice?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = model.connectionError {
                EmptyState(title: "服务未连接", systemImage: "bolt.slash", detail: error)
            } else if model.tasks.isEmpty {
                EmptyState(title: "暂无任务", systemImage: "checkmark.circle",
                           detail: "通过 CLI 或 MCP 注册任务后会显示在这里")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
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
                                    TaskRow(
                                        task: task,
                                        collector: collector(for: task.id),
                                        confirmingForget: Binding(
                                            get: { expandedTaskID == task.id },
                                            set: { expandedTaskID = $0 ? task.id : nil }
                                        ),
                                        onForget: { forget(task) }
                                    )
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
                Label(updater.statusText, systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.plain)
            .disabled(updater.isChecking)
            Spacer()
            Button { installCommandLineTools() } label: {
                Label(commandLineToolsInstalled ? "CLI 已安装" : "安装 CLI",
                      systemImage: commandLineToolsInstalled ? "checkmark.circle" : "terminal")
            }
            .buttonStyle(.plain)
            .disabled(commandLineToolsInstalled)
            .help("安装到 ~/.local/bin，无需管理员密码")
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

    private func installCommandLineTools() {
        do {
            let directory = try CommandLineInstaller.install()
            commandLineToolsInstalled = true
            installerNotice = InstallerNotice(
                title: "命令行工具已安装",
                message: "已安装到 \(directory.path)，无需管理员密码。\n\n让 Codex 使用 TaskBeacon：\ncodex mcp add taskbeacon -- \(directory.path)/taskbeacon-mcp"
            )
        } catch {
            installerNotice = InstallerNotice(title: "安装失败", message: error.localizedDescription)
        }
    }

    private func forget(_ task: TaskRecord) {
        expandedTaskID = nil
        Task {
            if let error = await model.forgetTask(id: task.id) {
                installerNotice = InstallerNotice(title: "停止跟踪失败", message: error)
            }
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

private struct InstallerNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum BeaconPalette {
    // Radix Colors: quiet Sage neutrals with semantic Grass, Amber and Tomato.
    // Keep the progress fill deliberately lighter than the status foreground.
    static let sage = adaptive(light: 0x5F6563, dark: 0xADB5B2)       // Sage 11
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
    @Binding var confirmingForget: Bool
    let onForget: () -> Void

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
                Text("更新于 \(task.updatedAt, style: .relative)")
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
                .help("更多操作")
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
                        .tint(progressColor)
                    Text(progressText(progress))
                        .font(.caption2).foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            if let error = collector?.lastError {
                Label("采集异常：\(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(BeaconPalette.amber)
                    .lineLimit(1)
            }
            if confirmingForget {
                Divider()
                HStack(spacing: 8) {
                    Label("不会终止实际任务", systemImage: "eye.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            confirmingForget = false
                        }
                    }
                    Button("停止跟踪", role: .destructive, action: onForget)
                }
                .controlSize(.small)
                .transition(.opacity.combined(with: .move(edge: .top)))
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

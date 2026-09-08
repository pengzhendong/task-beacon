import SwiftUI
import AppKit

@main
struct TaskBeaconMenuApp: App {
    @StateObject private var model: BeaconModel
    @StateObject private var updater: UpdateController

    init() {
        let model = BeaconModel()
        _model = StateObject(wrappedValue: model)
        _updater = StateObject(wrappedValue: UpdateController(model: model))
    }

    var body: some Scene {
        MenuBarExtra {
            BeaconMenu(model: model, updater: updater)
                .frame(width: 390, height: panelHeight)
                .animation(.easeInOut(duration: 0.18), value: model.tasks.count)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .renderingMode(MenuBarIcon.image.isTemplate ? .template : .original)
                .interpolation(.high)
                .frame(width: 22, height: 22)
                .accessibilityLabel("TaskBeacon")
                .accessibilityValue("\(model.activeCount) 个进行中，\(model.attentionCount) 个需处理")
                .help("TaskBeacon · \(model.activeCount) 个进行中 · \(model.attentionCount) 个需处理")
        }
        .menuBarExtraStyle(.window)
    }

    private var panelHeight: CGFloat {
        min(500, max(205, 120 + CGFloat(model.tasks.count) * 90))
    }
}

@MainActor
private enum MenuBarIcon {
    static let image: NSImage = {
        let icon: NSImage
        if let url = Bundle.main.url(forResource: "TaskBeaconStatus", withExtension: "png"),
           let bundledIcon = NSImage(contentsOf: url) {
            icon = bundledIcon
            icon.isTemplate = false
        } else {
            icon = NSImage(systemSymbolName: "terminal", accessibilityDescription: "TaskBeacon")
                ?? NSImage(size: NSSize(width: 22, height: 22))
            icon.isTemplate = true
        }
        // Keep the source pixels for Retina rendering while sizing the status item in points.
        icon.size = NSSize(width: 22, height: 22)
        return icon
    }()
}

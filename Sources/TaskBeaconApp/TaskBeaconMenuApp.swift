import SwiftUI
import AppKit

@main
struct TaskBeaconMenuApp: App {
    @StateObject private var model: BeaconModel
    @StateObject private var updater: UpdateController
    @State private var expandedTaskID: String?

    init() {
        CommandLineInstaller.installAutomatically()
        let model = BeaconModel()
        _model = StateObject(wrappedValue: model)
        _updater = StateObject(wrappedValue: UpdateController(model: model))
    }

    var body: some Scene {
        MenuBarExtra {
            BeaconMenu(model: model, updater: updater, expandedTaskID: $expandedTaskID)
                .frame(width: 390)
                .animation(.easeInOut(duration: 0.18), value: model.tasks.count)
                .animation(.easeInOut(duration: 0.18), value: expandedTaskID)
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

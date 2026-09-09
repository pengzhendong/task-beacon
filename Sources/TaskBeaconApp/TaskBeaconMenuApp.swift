import SwiftUI
import AppKit

@main
struct TaskBeaconMenuApp: App {
    @NSApplicationDelegateAdaptor(TaskBeaconAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
enum MenuBarIcon {
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

import AppKit
import Combine
import SwiftUI
import TaskBeaconCore

@MainActor
final class MenuPresentationState: ObservableObject {
    @Published var expandedTaskID: String?
    @Published var isPinned: Bool {
        didSet {
            UserDefaults.standard.set(isPinned, forKey: Self.pinDefaultsKey)
            onPinChange?(isPinned)
        }
    }

    var onPinChange: ((Bool) -> Void)?

    private static let pinDefaultsKey = "TaskBeaconMenuPinned"

    init() {
        isPinned = UserDefaults.standard.bool(forKey: Self.pinDefaultsKey)
    }
}

@MainActor
private struct TaskBeaconPopoverContent: View {
    @ObservedObject var model: BeaconModel
    @ObservedObject var presentation: MenuPresentationState
    let updater: UpdateController

    var body: some View {
        BeaconMenu(
            model: model,
            updater: updater,
            expandedTaskID: $presentation.expandedTaskID,
            isPinned: $presentation.isPinned
        )
        .frame(width: 390)
        .animation(.easeInOut(duration: 0.18), value: model.tasks.count)
        .animation(.easeInOut(duration: 0.18), value: presentation.expandedTaskID)
    }
}

@MainActor
final class TaskBeaconAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model: BeaconModel
    private let updater: UpdateController
    private let presentation = MenuPresentationState()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        CommandLineInstaller.installAutomatically()
        let model = BeaconModel()
        self.model = model
        updater = UpdateController(model: model)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configurePopover()
        presentation.onPinChange = { [weak self] isPinned in
            self?.applyPopoverBehavior(isPinned: isPinned)
        }
        model.$tasks
            .sink { [weak self] tasks in self?.updateStatusItem(for: tasks) }
            .store(in: &cancellables)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }
        button.image = MenuBarIcon.image
        button.image?.size = NSSize(width: 22, height: 22)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.setAccessibilityLabel("TaskBeacon")
        statusItem = item
        updateStatusItem(for: model.tasks)
    }

    private func configurePopover() {
        let content = TaskBeaconPopoverContent(
            model: model,
            presentation: presentation,
            updater: updater
        )
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.animates = true
        popover.delegate = self
        applyPopoverBehavior(isPinned: presentation.isPinned)
    }

    private func applyPopoverBehavior(isPinned: Bool) {
        popover.behavior = isPinned ? .applicationDefined : .transient
    }

    private func updateStatusItem(for tasks: [TaskRecord]) {
        let active = tasks.filter { !$0.status.isTerminal }.count
        let attention = tasks.filter { $0.status == .waiting || $0.status == .failed }.count
        let value = "\(active) 个进行中，\(attention) 个需处理"
        statusItem?.button?.toolTip = "TaskBeacon · \(active) 个进行中 · \(attention) 个需处理"
        statusItem?.button?.setAccessibilityValue(value)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

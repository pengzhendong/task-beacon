import SwiftUI
import AppKit
import Sparkle

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    private(set) var controller: SPUStandardUpdaterController!
    private let model: BeaconModel
    private var updateWillInstall = false
    private var daemonPrepared = false

    init(model: BeaconModel) {
        self.model = model
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate),
                                               name: NSApplication.willTerminateNotification, object: nil)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        updateWillInstall = true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        updateWillInstall = true
        return false
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        prepareDaemonForUpdate()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        updateWillInstall = false
        if daemonPrepared {
            daemonPrepared = false
            model.resumeAfterUpdateFailure()
        }
    }

    @objc private func applicationWillTerminate() {
        if updateWillInstall { prepareDaemonForUpdate() }
    }

    private func prepareDaemonForUpdate() {
        guard !daemonPrepared else { return }
        daemonPrepared = true
        model.prepareForApplicationUpdate()
    }
}

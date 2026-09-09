import SwiftUI
import AppKit
import Sparkle

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    private(set) var controller: SPUStandardUpdaterController!
    @Published private(set) var statusText = "检查更新"
    @Published private(set) var isChecking = false
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
        guard !controller.updater.sessionInProgress else { return }
        statusText = "正在检查…"
        isChecking = true
        // This is a direct response to the user's update action, so persist their
        // preference to download and install future updates automatically too.
        controller.updater.automaticallyDownloadsUpdates = true
        controller.updater.checkForUpdatesInBackground()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        statusText = "正在下载 \(item.displayVersionString)…"
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        isChecking = false
        statusText = "已是最新版本"
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        updateWillInstall = true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        updateWillInstall = true
        statusText = "正在安装并重启…"
        prepareDaemonForUpdate()
        DispatchQueue.main.async {
            immediateInstallHandler()
        }
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        statusText = "正在重新启动…"
        prepareDaemonForUpdate()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        updateWillInstall = false
        isChecking = false
        statusText = "更新失败"
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

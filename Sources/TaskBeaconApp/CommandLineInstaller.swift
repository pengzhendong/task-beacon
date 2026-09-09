import Foundation
import TaskBeaconCore

enum CommandLineInstaller {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin", isDirectory: true)

    private static let toolNames = ["taskbeacon", "taskbeacon-mcp"]

    static func installAutomatically() {
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL.path
        guard bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(userApplications + "/") else {
            return
        }
        do {
            try install()
        } catch {
            // Keep launching normally; installation failures remain visible in the system log.
            NSLog("TaskBeacon automatic CLI installation: %@", error.localizedDescription)
        }
    }

    @discardableResult
    static func install() throws -> URL {
        guard let bundledTools = Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true) else {
            throw TaskBeaconError.notFound("应用包内没有找到命令行工具")
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        let pairs = try toolNames.map { name -> (source: URL, link: URL) in
            let source = bundledTools.appendingPathComponent(name)
            guard fileManager.isExecutableFile(atPath: source.path) else {
                throw TaskBeaconError.notFound("应用包内没有找到 \(name)")
            }
            return (source, directory.appendingPathComponent(name))
        }

        // Refuse to replace files owned by the user. Existing TaskBeacon links
        // are harmless and remain stable when the app updates in place.
        for pair in pairs where pathExists(pair.link) && !link(at: pair.link, pointsTo: pair.source) {
            throw TaskBeaconError.invalid("\(pair.link.path) 已存在，请先移动或删除它")
        }
        for pair in pairs where !pathExists(pair.link) {
            try fileManager.createSymbolicLink(at: pair.link, withDestinationURL: pair.source)
        }
        return directory
    }

    private static func pathExists(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func link(at linkURL: URL, pointsTo sourceURL: URL) -> Bool {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path) else {
            return false
        }
        let resolvedDestination: URL
        if destination.hasPrefix("/") {
            resolvedDestination = URL(fileURLWithPath: destination)
        } else {
            resolvedDestination = linkURL.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return resolvedDestination.standardizedFileURL.path == sourceURL.standardizedFileURL.path
    }
}

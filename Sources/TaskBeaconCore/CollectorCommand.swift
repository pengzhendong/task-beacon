import Foundation

public enum CollectorCommand {
    /// Preserve shell commands, but safely quote a command that is exactly an
    /// existing filesystem path. This makes the common `--command /path/to/script`
    /// form work even when a path component contains spaces or shell metacharacters.
    public static func normalized(_ command: String, workingDirectory: String? = nil) -> String {
        guard command.contains("/") else { return command }

        let candidate: URL
        if command.hasPrefix("/") {
            candidate = URL(fileURLWithPath: command)
        } else if let workingDirectory {
            candidate = URL(fileURLWithPath: workingDirectory, isDirectory: true)
                .appendingPathComponent(command)
        } else {
            candidate = URL(fileURLWithPath: command)
        }

        guard FileManager.default.fileExists(atPath: candidate.standardizedFileURL.path) else {
            return command
        }
        return shellQuoted(command)
    }

    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

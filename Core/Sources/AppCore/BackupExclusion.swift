import Foundation

/// Keeps the managed checkouts out of Time Machine.
///
/// A worktree and a clone both rebuild from the remote, so a backup of them costs the user
/// tens of gigabytes and buys nothing. Spotlight is a separate problem, solved by the
/// `.noindex` suffix on the worktree directory name.
///
/// The flag is a directory attribute and children inherit it, so one call per root is enough.
public enum BackupExclusion {
    /// Marks each existing path as excluded from backups. Returns the paths it changed, so a
    /// caller can report what happened. A path that is absent or refuses the attribute is
    /// skipped: exclusion is an optimisation, never a precondition for running.
    @discardableResult
    public static func exclude(paths: [String]) -> [String] {
        var changed: [String] = []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            var url = URL(fileURLWithPath: path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            guard (try? url.setResourceValues(values)) != nil else { continue }
            changed.append(path)
        }
        return changed
    }
}

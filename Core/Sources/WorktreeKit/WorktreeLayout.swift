/// Where managed worktrees live under the managed root.
///
/// The `.noindex` suffix keeps Spotlight out of the tree. A checkout of a large repo runs
/// to gigabytes, and `mds_stores` indexes all of it otherwise. A `.metadata_never_index`
/// marker file was tested and does not work; the directory-name suffix does.
public enum WorktreeLayout {
    public static let directoryName = "worktrees.noindex"
    public static let legacyDirectoryName = "worktrees"

    public static func directory(managedRoot: String) -> String {
        managedRoot + "/" + directoryName
    }

    public static func legacyDirectory(managedRoot: String) -> String {
        managedRoot + "/" + legacyDirectoryName
    }

    /// Returns the new path for a worktree still under the legacy root, or nil when the
    /// path needs no change.
    public static func migratedPath(_ path: String, managedRoot: String) -> String? {
        let legacyPrefix = legacyDirectory(managedRoot: managedRoot) + "/"
        guard path.hasPrefix(legacyPrefix) else { return nil }
        return directory(managedRoot: managedRoot) + "/" + String(path.dropFirst(legacyPrefix.count))
    }
}

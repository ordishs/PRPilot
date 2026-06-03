import Foundation

public enum BranchName {
    /// Whether `name` is a valid git branch name (a usable subset of `git check-ref-format`).
    /// Rejects the common mistakes — spaces, control chars, `~^:?*[\`, `..`, `//`, `@{`,
    /// leading/trailing `/` or `.`, a trailing `.lock`, and the bare `@`.
    public static func isValid(_ name: String) -> Bool {
        if name.isEmpty { return false }
        if name.hasPrefix("/") || name.hasSuffix("/") { return false }
        if name.hasPrefix(".") || name.hasSuffix(".") { return false }
        if name.hasSuffix(".lock") { return false }
        if name == "@" { return false }
        if name.contains("..") || name.contains("//") || name.contains("@{") { return false }
        let forbidden: Set<Character> = [" ", "\t", "~", "^", ":", "?", "*", "[", "\\"]
        for ch in name {
            if forbidden.contains(ch) { return false }
            if let ascii = ch.asciiValue, ascii < 0x20 || ascii == 0x7f { return false }
        }
        return true
    }
}

import Testing
import Foundation
@testable import AppCore

private func tempDirectory() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("backup-excl-\(UUID().uuidString)", isDirectory: true).path
}

private func isExcluded(_ path: String) throws -> Bool {
    let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isExcludedFromBackupKey])
    return values.isExcludedFromBackup ?? false
}

@Test func exclusionSetsTheFlagOnAnExistingDirectory() throws {
    let root = tempDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    #expect(try isExcluded(root) == false)

    let changed = BackupExclusion.exclude(paths: [root])

    #expect(changed == [root])
    #expect(try isExcluded(root) == true)
}

@Test func exclusionSkipsAPathThatDoesNotExist() throws {
    let root = tempDirectory()
    let missing = root + "/absent"

    let changed = BackupExclusion.exclude(paths: [missing])

    #expect(changed.isEmpty)
}

@Test func exclusionReportsOnlyThePathsItChanged() throws {
    let root = tempDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let present = root + "/present"
    let absent = root + "/absent"
    try FileManager.default.createDirectory(atPath: present, withIntermediateDirectories: true)

    let changed = BackupExclusion.exclude(paths: [absent, present])

    #expect(changed == [present])
    #expect(try isExcluded(present) == true)
}

import SwiftUI
import PRPilotModels
import AppCore
import DiffKit

struct DiffToolbarView: View {
    let model: AppModel
    let review: Review
    let fileCount: Int
    let addedCount: Int
    let removedCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Picker("Diff mode", selection: Binding(
                get: { model.diffMode },
                set: { newValue in Task { await model.setDiffMode(newValue) } }
            )) {
                Text("Unified").tag(DiffMode.unified)
                Text("Split").tag(DiffMode.split)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)

            HStack(spacing: 6) {
                Text("+\(addedCount)").foregroundStyle(.green)
                Text("−\(removedCount)").foregroundStyle(.red)
                Text("\(fileCount) file\(fileCount == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            .font(.callout.monospacedDigit())

            Button(action: {
                Task { await model.loadDiff(for: review, force: true) }
            }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh diff")

            Spacer()

            if let path = model.registeredClonePath(for: review) {
                Label("local: \(tildeShortened(path))", systemImage: "folder.fill")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func tildeShortened(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

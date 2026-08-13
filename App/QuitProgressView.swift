import AppCore
import SwiftUI

/// What the user sees while the app waits for agent processes to exit.
///
/// The wait is short but not instant, and the main window has already gone by then. Without this
/// panel the app looks hung, and a user who force-quits during the wait leaves exactly the
/// runaway processes the wait exists to stop. So the panel names what it waits for and says
/// plainly that force-quitting is the wrong move.
struct QuitProgressView: View {
    let progress: ShutdownProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                // The bar animates its value by default, so on the last step it is still sliding
                // when the text already reads as finished. The two must agree.
                .animation(nil, value: progress.fraction)
            remainingList
            Label(
                "Force quitting now leaves agent processes running. They keep using CPU until you restart.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 380, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            // A spinner still turning under "all processes have exited" reads as unfinished work.
            // The slot keeps a fixed width so the text does not shift when the two swap.
            Group {
                if progress.isFinished {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }
            }
            .frame(width: 16, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                Text("Quitting PR Pilot")
                    .font(.headline)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// Counts down as each agent's processes leave the process table, so the panel is visibly
    /// making progress rather than just spinning.
    private var status: String {
        guard !progress.isFinished else { return "All agent processes have exited." }
        let noun = progress.remaining == 1 ? "agent" : "agents"
        return "Waiting for \(progress.remaining) \(noun) to shut down and their processes to exit…"
    }

    @ViewBuilder
    private var remainingList: some View {
        if !progress.stopping.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(progress.stopping, id: \.self) { title in
                    HStack(spacing: 7) {
                        Image(systemName: "hourglass")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(title)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.leading, 2)
        }
    }
}

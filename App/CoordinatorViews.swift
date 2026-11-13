import AppKit
import SwiftUI
import PRPilotModels
import AppCore

struct CoordinatorPill: View {
    let model: AppModel

    var body: some View {
        let count = model.nextUpRows.count

        Button {
            model.coordinatorPanelOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "list.number")
                Text("\(count)").monospacedDigit()

                if model.settings.coordinatorAuto {
                    Text("AUTO")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.25))
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(count > 0 ? Color.orange : Color.secondary)
        }
        .help(count == 0 ? "Nothing needs you" : "\(count) \(count == 1 ? "ticket needs" : "tickets need") you · show Next up")
    }
}

struct CoordinatorResizeHandle: View {
    @Binding var width: Double
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 1)
            .overlay(Color.clear.frame(width: 8).contentShape(Rectangle()))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = startWidth ?? width
                        startWidth = base
                        width = min(max(base - value.translation.width, 280), 700)
                    }
                    .onEnded { _ in startWidth = nil }
            )
    }
}

struct CoordinatorPanel: View {
    let model: AppModel
    @Binding var viewMode: MainViewMode
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            nextUpList
            Divider()
            logSection
            Divider()
            coordinatorSection
        }
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Next up").font(.headline)
            Spacer()
            Toggle("AUTO", isOn: autoBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("AUTO starts the next step for you. It never merges a PR and never posts a review or a comment.")
            Button {
                model.coordinatorPanelOpen = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(10)
    }

    private var autoBinding: Binding<Bool> {
        Binding(
            get: { model.settings.coordinatorAuto },
            set: { newValue in
                var updated = model.settings
                updated.coordinatorAuto = newValue
                Task {
                    await model.updateSettings(updated)
                    await model.runCoordinatorPass()
                }
            }
        )
    }

    private var nextUpList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if model.nextUpRows.isEmpty {
                    Text("Nothing needs you right now.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(10)
                }

                ForEach(model.nextUpRows) { row in
                    NextUpRowView(model: model, row: row, viewMode: $viewMode)
                }
            }
            .padding(8)
        }
        .frame(minHeight: 120, maxHeight: 280)
    }

    private var logSection: some View {
        DisclosureGroup(isExpanded: $showLog) {
            VStack(alignment: .leading, spacing: 4) {
                if model.autoLog.isEmpty {
                    Text("AUTO has done nothing yet.").foregroundStyle(.secondary)
                }

                ForEach(Array(model.autoLog.reversed().enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(entry.title) · \(entry.action)").lineLimit(1)
                        Text("\(entry.at.formatted(date: .omitted, time: .shortened)) · \(entry.result)")
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Text("AUTO log (\(model.autoLog.count))").font(.system(size: 12, weight: .medium))
        }
        .padding(10)
    }

    private var coordinatorSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Coordinator").font(.system(size: 12, weight: .medium))
                Spacer()

                if model.coordinatorSession != nil {
                    Button("Stop") { model.stopCoordinator() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if let session = model.coordinatorSession {
                TerminalHost(session: session)
                    .frame(minHeight: 200)
            } else {
                VStack(spacing: 8) {
                    Button("Ask the coordinator") {
                        Task { await model.startCoordinator() }
                    }
                    Text("A read-only agent that knows every ticket. Ask it which PRs need a rebase or are ready to merge. It cannot merge, post or push.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if let error = model.coordinatorError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct NextUpRowView: View {
    let model: AppModel
    let row: NextUpRow
    @Binding var viewMode: MainViewMode

    var body: some View {
        let item = model.reviews.first { $0.id == row.itemID }

        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(item)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(row.reason).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(label) { run() }
                .controlSize(.small)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            viewMode = .list
            model.jump(to: row.itemID)
        }
    }

    private func title(_ item: WorkItem?) -> String {
        guard let item else { return "Ticket" }
        guard let number = item.displayNumber else { return item.title }

        return "#\(number) \(item.title)"
    }

    private var label: String {
        switch row.step {
        case .startReview: return "Start review"
        case .startFix: return "Start fix"
        case .rebase: return "Rebase"
        case .continueWork: return "Continue"
        case .open: return "Open"
        }
    }

    private func run() {
        if row.step == .open || row.step == .continueWork {
            viewMode = .list
        }

        Task { _ = await model.performStep(row.step, row: row, auto: false) }
    }
}

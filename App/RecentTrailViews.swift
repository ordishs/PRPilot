import SwiftUI
import PRPilotModels
import AppCore

struct TrailRow: View {
    let model: AppModel
    let recent: AppModel.RecentItem
    let isCurrent: Bool
    let isHighlighted: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .opacity(isCurrent ? 1 : 0)

            StatusDot(status: model.claudeStatuses[recent.item.id])

            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(trailTabLabel(for: recent.item, defaultAgent: model.settings.defaultAgent))
                .font(.system(size: 10))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.5)))

            Text(trailAgeLabel(since: recent.visitedAt, now: now))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(minWidth: 28, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isHighlighted ? Color.accentColor.opacity(0.25) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private var title: String {
        guard let number = recent.item.displayNumber else { return recent.item.title }

        return "#\(number) \(recent.item.title)"
    }
}

struct RecentButton: View {
    let model: AppModel
    @Binding var viewMode: MainViewMode
    @State private var isShowing = false
    @State private var openedAt = Date()

    var body: some View {
        Button {
            openedAt = Date()
            isShowing.toggle()
        } label: {
            Label("Recent", systemImage: "clock.arrow.circlepath")
        }
        .help("Tickets you opened, newest first (⌃Tab goes to the previous one)")
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                if model.recentItems.isEmpty {
                    Text("No recent tickets")
                        .foregroundStyle(.secondary)
                        .padding(8)
                }

                ForEach(model.recentItems) { recent in
                    Button {
                        isShowing = false
                        viewMode = .list
                        model.jump(to: recent.id)
                    } label: {
                        TrailRow(
                            model: model,
                            recent: recent,
                            isCurrent: recent.id == model.selection,
                            isHighlighted: false,
                            now: openedAt
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(width: 340)
        }
    }
}

struct TrailSwitcherOverlay: View {
    let model: AppModel
    let controller: TrailSwitcherController

    var body: some View {
        if let highlight = controller.switcher.highlight {
            let ids = controller.switcher.ids
            let recents = Dictionary(model.recentItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let now = Date()

            VStack(alignment: .leading, spacing: 2) {
                Text("Recent")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)

                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    if let recent = recents[id] {
                        TrailRow(
                            model: model,
                            recent: recent,
                            isCurrent: index == 0,
                            isHighlighted: index == highlight,
                            now: now
                        )
                    }
                }
            }
            .padding(8)
            .frame(width: 420)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 20)
            .transaction { $0.animation = nil }
        }
    }
}

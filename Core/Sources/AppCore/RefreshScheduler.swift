import Foundation

/// Chooses which work items to refresh on a poll cycle.
///
/// Refreshing every open PR each cycle spawns one `gh` per PR. At 18 PRs and a 60 second
/// interval that is a subprocess every three seconds, forever. The selected item still
/// refreshes every cycle; the rest take turns, most stale first.
public enum RefreshScheduler {
    public static func itemsToRefresh(
        openIDs: [String],
        selectedID: String?,
        lastRefreshedAt: [String: Date],
        batchSize: Int
    ) -> [String] {
        var chosen: [String] = []
        if let selectedID, openIDs.contains(selectedID) {
            chosen.append(selectedID)
        }

        let others = openIDs
            .filter { $0 != selectedID }
            .sorted { left, right in
                let leftStamp = lastRefreshedAt[left] ?? .distantPast
                let rightStamp = lastRefreshedAt[right] ?? .distantPast
                if leftStamp == rightStamp { return left < right }
                return leftStamp < rightStamp
            }
        chosen.append(contentsOf: others.prefix(max(0, batchSize)))
        return chosen
    }
}

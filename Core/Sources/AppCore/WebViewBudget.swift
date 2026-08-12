/// Chooses which web views to tear down once the cap is exceeded. A web view has no
/// busy state, so unlike `SessionBudget` the only exemption is the selected item.
public enum WebViewBudget {
    /// - Parameter activationOrder: item ids, most recently activated first.
    /// - Returns: the ids to evict, oldest first.
    public static func evictions(
        activationOrder: [String],
        cap: Int,
        selectedID: String?
    ) -> [String] {
        guard cap > 0, activationOrder.count > cap else { return [] }

        let overflow = activationOrder.count - cap

        var victims: [String] = []
        for id in activationOrder.reversed() {
            if victims.count == overflow { break }
            if id == selectedID { continue }
            victims.append(id)
        }
        return victims
    }
}

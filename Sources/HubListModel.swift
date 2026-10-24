import Foundation
import Observation

// What the list shows, worked out once per change of input. The view used to do
// all of this inside body, where a change of loading or of error paid again for
// five filter walks, a category walk and a tag walk over the whole index.
@MainActor @Observable final class HubListModel {
    // Everything the derived values depend on. The index travels as a revision
    // because comparing five thousand rows on every body pass is the cost this
    // type exists to remove.
    struct Key: Equatable {
        var revision = 0
        var prefs = HubPrefs()
        var filter = HubFilter.recent
        var query = ""
        var tags: [String] = []
        var category = ""
        // The day, not the instant: the thirty day window does not move between
        // two body passes a second apart, so they must not both pay for a walk.
        var day = Date.distantPast
    }
    private(set) var results: [HubItem] = []
    private(set) var counts: [HubFilter: Int] = [:]
    private(set) var categories: [HubFacet] = []
    private(set) var tagFacets: [HubFacet] = []
    private(set) var unread: [HubInboxEntry] = []
    // Read by HubListModelTests. Deliberately not behind DEBUG, so the test
    // counts the work the shipped build does.
    @ObservationIgnored private(set) var computations = 0
    @ObservationIgnored private var key: Key?

    // app.js selectItems 236 / renderChips 120 / renderCatbar 2020 / renderTagbar 2050,
    // in the order the screen reads them.
    func update(_ next: Key, now: Date, items: [HubItem], inbox: [HubInboxEntry],
                itemByID: [String: HubItem]) {
        guard key != next else { return }
        key = next
        computations += 1
        results = HubRules.selectItems(items, query: next.query, filter: next.filter.rawValue, now: now,
                                       prefs: next.prefs, tags: next.tags, category: next.category)
        var chips: [HubFilter: Int] = [:]
        for item in items {
            for chip in HubFilter.allCases
            where HubRules.matchesFilter(item, filter: chip.rawValue, now: now, prefs: next.prefs) {
                chips[chip, default: 0] += 1
            }
        }
        counts = chips
        categories = HubRules.categoryRows(items, selected: next.category)
        tagFacets = HubRules.tagRows(results, selected: next.tags)
        unread = HubRules.selectUnreadInbox(inbox, itemByID: itemByID, prefs: next.prefs)
    }
}

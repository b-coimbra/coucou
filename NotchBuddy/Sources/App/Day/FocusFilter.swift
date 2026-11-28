#if !APPSTORE
import Foundation

// MARK: - Which pills stay while Do not disturb is on (pure logic)

/// What the filter needs to know about one pill.
struct FocusPill: Sendable, Equatable {
    let id: String
    /// A coding tool or an agent: its amber dot means something waits for you. On a service
    /// pill the same dot only means there is news.
    var isAgent = false
    /// Waiting for a permission or an answer
    var isWaiting = false
    var hasApprovalBadge = false
    /// A session popped out of its client's pill because it waits for you
    var isPoppedOut = false

    var needsYou: Bool { isWaiting || isPoppedOut || (isAgent && hasApprovalBadge) }
}

enum FocusFilter {
    /// The pills left out. Kept: those that wait for you, those in `urgent` (a pending
    /// approval or question, a meeting about to start), and the ones in `always` (the main
    /// pill and the one on the card).
    static func hidden(_ pills: [FocusPill], urgent: Set<String>, always: Set<String>) -> Set<String> {
        Set(pills.filter { !$0.needsYou && !urgent.contains($0.id) && !always.contains($0.id) }.map(\.id))
    }
}
#endif

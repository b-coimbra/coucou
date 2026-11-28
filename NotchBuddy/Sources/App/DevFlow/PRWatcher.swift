#if !APPSTORE
import Foundation

/// Reads the pull requests every 3 minutes, while "My PRs", "Reviews" or the CI alert is on.
@MainActor
final class PRWatcher {
    static let shared = PRWatcher()
    private static let interval: TimeInterval = 180

    private let queue = DispatchQueue(label: "fr.louisraille.PRWatcher", qos: .utility)
    private var loop: Task<Void, Never>?
    private var wantsMine = false
    private var wantsReviews = false
    /// Changes with the configuration: a poll started before it is dropped.
    private var generation = 0
    private var cancellation = DevCancellation()
    private var inFlight = false
    private var lastPoll = Date.distantPast
    /// The checks at the last poll, to tell when they finish.
    private var checks: [String: PRCheckState] = [:]

    private init() {}

    func configure(mine: Bool, reviews: Bool) {
        guard mine != wantsMine || reviews != wantsReviews else { return }
        wantsMine = mine
        wantsReviews = reviews
        generation += 1
        cancellation.cancel()
        cancellation = DevCancellation()
        inFlight = false
        loop?.cancel()
        loop = nil

        let store = DevFlowStore.shared
        if !mine {
            checks = [:]
            store.setIfChanged(\.myPRs, [])
            store.setIfChanged(\.myPRsLoaded, false)
        }
        if !reviews {
            store.setIfChanged(\.reviews, [])
            store.setIfChanged(\.reviewsLoaded, false)
        }
        guard mine || reviews else {
            store.setIfChanged(\.ghFailure, nil)
            return
        }
        loop = Task { [weak self] in
            // Not in the way of the launch.
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(PRWatcher.interval), tolerance: .seconds(15))
            }
        }
    }

    /// A card came on screen. No-op while off.
    func refreshIfStale(maxAge: TimeInterval = 60) {
        guard loop != nil, Date().timeIntervalSince(lastPoll) > maxAge else { return }
        Task { await poll() }
    }

    private func poll() async {
        guard wantsMine || wantsReviews, !inFlight, !DemoEngine.isPollerPaused else { return }
        inFlight = true
        lastPoll = Date()
        let started = generation
        let mine = wantsMine, reviews = wantsReviews
        let cancellation = self.cancellation
        let queue = self.queue
        let result: GHFetch = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: GHClient.fetch(mine: mine, reviews: reviews,
                                                              cancellation: cancellation))
            }
        }
        guard started == generation else { return }
        inFlight = false
        apply(result)
    }

    private func apply(_ result: GHFetch) {
        let store = DevFlowStore.shared
        store.setIfChanged(\.ghFailure, result.failure)
        if let reviews = result.reviews {
            store.setIfChanged(\.reviews, reviews)
            store.setIfChanged(\.reviewsLoaded, true)
        }
        if let mine = result.mine { applyMine(mine) }
        DevFlowController.shared.syncPills()
    }

    private func applyMine(_ mine: [GHFetch.Mine]) {
        let store = DevFlowStore.shared
        let before = Dictionary(store.myPRs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [PRRow] = []
        var current: [String: PRCheckState] = [:]
        var latest: [String: Double] = [:]
        for item in mine {
            let id = item.summary.id
            // One that couldn't be read keeps what was known: no false news, no lost alert.
            let detail = item.detail ?? before[id]?.detail
            rows.append(PRRow(summary: item.summary, detail: detail))
            if let state = item.detail?.checks ?? checks[id] { current[id] = state }
            if let detail { latest[id] = detail.latestActivity?.timeIntervalSince1970 ?? 0 }
        }

        let finished = CITransition.between(previous: checks, current: current)
        checks = current

        let saved = UserDefaults.standard.dictionary(forKey: DevFlowSettings.prSeenKey) as? [String: Double]
        let update = PRSeen.update(saved: saved, latest: latest, open: Set(rows.map(\.id)))
        // Nothing could be read the very first time: there is no starting point yet.
        if saved != nil || !latest.isEmpty || rows.isEmpty {
            UserDefaults.standard.set(update.seen, forKey: DevFlowSettings.prSeenKey)
        }
        for i in rows.indices { rows[i].unseen = update.unseen.contains(rows[i].id) }

        store.setIfChanged(\.myPRs, rows)
        store.setIfChanged(\.myPRsLoaded, true)

        // One flash for what finished together; a failure wins over a success.
        if DevFlowSettings.ciAlert, !finished.isEmpty {
            let failed = finished.contains { !$0.passed }
            EdgeLightController.shared.flash(colorHex: failed ? "#F4505E" : "#22C55E")
        }
    }

    /// The user saw these rows: their reviews and comments are no longer news.
    func markSeen(_ ids: Set<String>) {
        let store = DevFlowStore.shared
        var seen = UserDefaults.standard.dictionary(forKey: DevFlowSettings.prSeenKey) as? [String: Double] ?? [:]
        var rows = store.myPRs
        for i in rows.indices where ids.contains(rows[i].id) {
            if let latest = rows[i].detail?.latestActivity { seen[rows[i].id] = latest.timeIntervalSince1970 }
            rows[i].unseen = false
        }
        UserDefaults.standard.set(seen, forKey: DevFlowSettings.prSeenKey)
        store.setIfChanged(\.myPRs, rows)
        DevFlowController.shared.syncPills()
    }
}
#endif

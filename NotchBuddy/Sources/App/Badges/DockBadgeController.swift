#if !APPSTORE
import AppKit
import Combine

/// What the badge pills show. In memory only.
@MainActor
final class BadgeStore: ObservableObject {
    static let shared = BadgeStore()

    /// No entry until the app's badge has been read
    @Published var badges: [BadgeApp: DockBadge] = [:]

    private init() {}

    func badge(_ app: BadgeApp) -> DockBadge { badges[app] ?? .none }

    /// A @Published set redraws every card, even with the same value.
    func setIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<BadgeStore, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

/// Reads the badges of the pills that are on every 20 s, off the main thread. Nothing runs
/// while both are off.
@MainActor
final class DockBadgeController {
    static let shared = DockBadgeController()
    private static let interval = 20

    private let queue = DispatchQueue(label: "fr.louisraille.DockBadgeWatcher", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var wanted: Set<BadgeApp> = []
    /// Changes with the configuration: a look started before it is dropped.
    private var generation = 0
    private var subscriptions: Set<AnyCancellable> = []

    private init() {}

    /// Called once at launch.
    func start() {
        guard subscriptions.isEmpty else { return }
        AppState.shared.$activeIntegrations
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.configure(Set(BadgeApp.allCases.filter { active.contains($0.pillId) }))
            }
            .store(in: &subscriptions)
    }

    private func configure(_ apps: Set<BadgeApp>) {
        guard apps != wanted else {
            syncPills()
            return
        }
        wanted = apps
        generation += 1
        timer?.cancel()
        timer = nil
        let store = BadgeStore.shared
        store.setIfChanged(\.badges, store.badges.filter { apps.contains($0.key) })
        guard !apps.isEmpty else {
            syncPills()
            return
        }
        let generation = self.generation
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(Self.interval), leeway: .seconds(5))
        timer.setEventHandler { @Sendable in
            let result = DockBadgeController.look(apps)
            DispatchQueue.main.async {
                DockBadgeController.shared.apply(result, generation: generation)
            }
        }
        timer.resume()
        self.timer = timer
        syncPills()
    }

    private nonisolated static func look(_ apps: Set<BadgeApp>) -> [BadgeApp: DockBadge] {
        var badges: [BadgeApp: DockBadge] = [:]
        for app in apps {
            if let badge = DockBadgeReader.read(bundleId: app.bundleId).badge { badges[app] = badge }
        }
        return badges
    }

    /// Reads now: a card or the settings page came on screen. No-op while off.
    func refresh() {
        guard !wanted.isEmpty else { return }
        let apps = wanted, generation = self.generation
        queue.async { @Sendable in
            let result = DockBadgeController.look(apps)
            DispatchQueue.main.async {
                DockBadgeController.shared.apply(result, generation: generation)
            }
        }
    }

    private func apply(_ result: [BadgeApp: DockBadge], generation: Int) {
        guard generation == self.generation, !DemoEngine.isPollerPaused else { return }
        let store = BadgeStore.shared
        // An app that couldn't be read keeps what was known.
        store.setIfChanged(\.badges, store.badges.merging(result) { _, new in new })
        syncPills()
    }

    /// The pills' names: the app and its count.
    private func syncPills() {
        let state = AppState.shared
        for app in BadgeApp.allCases {
            guard let i = state.tasks.firstIndex(where: { $0.id == app.pillId }),
                  let name = PillCatalog.definition(for: app.pillId)?.name else { continue }
            let shown = BadgeStore.shared.badge(app).text.map { "\(name) \($0)" } ?? name
            if state.tasks[i].name != shown { state.tasks[i].name = shown }
        }
    }
}

/// What a click does: opens the app.
@MainActor
enum BadgeActions {
    static func open(_ app: BadgeApp) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
    }
}
#endif

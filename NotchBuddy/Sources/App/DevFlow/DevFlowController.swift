#if !APPSTORE
import AppKit
import Combine

/// What the dev flow's cards show. In memory only.
@MainActor
final class DevFlowStore: ObservableObject {
    static let shared = DevFlowStore()

    // The active repository (RepoWatcher)
    @Published var repo: GitRepoSnapshot?
    @Published var repoLoaded = false
    var repoEditorBundleId: String?
    @Published var jiraKey: String?
    @Published var jira: JiraState = .noCredentials

    // Pull requests (PRWatcher)
    @Published var myPRs: [PRRow] = []
    @Published var myPRsLoaded = false
    @Published var reviews: [PRSummary] = []
    @Published var reviewsLoaded = false
    @Published var ghFailure: GHFailure?

    private init() {}

    /// A @Published set redraws every card, even with the same value.
    func setIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<DevFlowStore, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

/// Starts and stops the watchers with the settings: nothing runs for a feature that is off.
@MainActor
final class DevFlowController {
    static let shared = DevFlowController()
    private var subscriptions: Set<AnyCancellable> = []

    private init() {}

    /// Called once at launch.
    func start() {
        guard subscriptions.isEmpty else { return }
        AppState.shared.$activeIntegrations
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &subscriptions)
        // The CI alert only polls while the Edge Light can show it. objectWillChange comes
        // before the new value is stored: applied on the next turn.
        EdgeLightSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &subscriptions)
        AppState.shared.$mode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { mode in
                if mode == .expanded { RepoWatcher.shared.refreshIfStale(maxAge: 3) }
            }
            .store(in: &subscriptions)
        apply()
    }

    /// Brings the watchers in line with the settings. Safe to call at any time.
    func apply() {
        let active = AppState.shared.activeIntegrations
        let ciAlert = DevFlowSettings.ciAlert && EdgeLightSettings.shared.enabled
        PRWatcher.shared.configure(mine: active.contains(DevFlowPills.pullRequests) || ciAlert,
                                   reviews: active.contains(DevFlowPills.reviews))
        RepoWatcher.shared.configure(branch: active.contains(DevFlowPills.branch),
                                     jira: active.contains(DevFlowPills.jira))
        syncPills()
    }

    /// The pills' names (key, counts, branch) and the dot of the pull request pill.
    func syncPills() {
        let state = AppState.shared
        let store = DevFlowStore.shared
        for id in DevFlowPills.all {
            guard let i = state.tasks.firstIndex(where: { $0.id == id }),
                  let name = PillCatalog.definition(for: id)?.name else { continue }
            let shown: String
            switch id {
            case DevFlowPills.jira:
                shown = store.jiraKey ?? name
            case DevFlowPills.pullRequests:
                shown = store.myPRsLoaded ? "\(name) \(store.myPRs.count)" : name
            case DevFlowPills.reviews:
                shown = store.reviewsLoaded ? "\(name) \(store.reviews.count)" : name
            default:
                // "feat/POC-1-login" reads better in a pill without its folder.
                shown = store.repo?.branch.split(separator: "/").last.map(String.init) ?? name
            }
            if state.tasks[i].name != shown { state.tasks[i].name = shown }
        }
        syncAttentionDot()
    }

    /// The dot stays while a pull request has news and its card isn't on screen. Checked
    /// after every poll, because focusing the pill removes badges.
    private func syncAttentionDot() {
        let state = AppState.shared
        let id = DevFlowPills.pullRequests
        guard let i = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        let onScreen = state.mode == .expanded && state.view == .overview && state.focusId == id
        if !onScreen && DevFlowStore.shared.myPRs.contains(where: \.unseen) {
            if state.tasks[i].pillBadge != .approval { state.tasks[i].pillBadge = .approval }
        } else if state.tasks[i].pillBadge == .approval {
            state.tasks[i].pillBadge = nil
        }
    }
}

/// What a click does: opens a web address built from structured fields, or an app.
@MainActor
enum DevFlowActions {
    static func openPill(_ id: String) {
        switch id {
        case DevFlowPills.jira:         openJira()
        case DevFlowPills.pullRequests: open("https://github.com/pulls")
        case DevFlowPills.reviews:      open("https://github.com/pulls/review-requested")
        default:                        openRepository()
        }
    }

    /// The current issue's page, else the Jira site.
    static func openJira() {
        let site = DevFlowSettings.jiraSite
        let url = DevFlowStore.shared.jiraKey.flatMap { JiraIssueKey.browseURL(site: site, key: $0) }
            ?? JiraIssueKey.site(site)
        if let url { NSWorkspace.shared.open(url) }
    }

    static func open(_ ref: PRRef) {
        if let url = ref.url { NSWorkspace.shared.open(url) }
    }

    /// Brings the editor the repository was found in forward, else shows the folder.
    static func openRepository() {
        let store = DevFlowStore.shared
        if let id = store.repoEditorBundleId,
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: app, configuration: .init(), completionHandler: nil)
        } else if let path = store.repo?.path {
            // Revealed, never opened: a folder is not launched whatever its name.
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
        }
    }

    private static func open(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}
#endif

#if !APPSTORE
import AppKit

/// Reads the active repository for the branch glance and the Jira card, while one of them is
/// on: every 10 s with the island open, every minute at rest, never while it is hidden.
@MainActor
final class RepoWatcher {
    static let shared = RepoWatcher()
    private static let jiraInterval: TimeInterval = 180

    private let queue = DispatchQueue(label: "fr.louisraille.RepoWatcher", qos: .utility)
    private let reader = RepoReader()
    private var loop: Task<Void, Never>?
    private var wantsBranch = false
    private var wantsJira = false
    private var generation = 0
    private var inFlight = false
    private var lastRead = Date.distantPast
    /// The Jira call last made ("site|key"), and when.
    private var jiraRequest: (id: String, at: Date)?

    private init() {}

    func configure(branch: Bool, jira: Bool) {
        guard branch != wantsBranch || jira != wantsJira else { return }
        wantsBranch = branch
        wantsJira = jira
        restart()
    }

    /// The folder, the pinned repository, the Jira site or the credentials changed.
    func settingsChanged() {
        let reader = self.reader
        queue.async { reader.forgetRepositories() }
        restart()
    }

    private func restart() {
        generation += 1
        inFlight = false
        lastRead = .distantPast
        jiraRequest = nil
        loop?.cancel()
        loop = nil
        let store = DevFlowStore.shared
        if !wantsJira {
            store.setIfChanged(\.jiraKey, nil)
            store.setIfChanged(\.jira, .noCredentials)
        }
        guard wantsBranch || wantsJira else {
            store.setIfChanged(\.repo, nil)
            store.setIfChanged(\.repoLoaded, false)
            store.repoEditorBundleId = nil
            return
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(10), tolerance: .seconds(2))
            }
        }
    }

    private func tick() async {
        let mode = AppState.shared.mode
        guard mode != .hidden || glanceShowsKey else { return }
        guard mode == .expanded || Date().timeIntervalSince(lastRead) >= 60 else { return }
        await read()
    }

    /// The notch glance shows the Jira key beside the hidden island too (off until turned
    /// on): the branch is then read once a minute there, without asking Jira.
    private var glanceShowsKey: Bool {
        let state = AppState.shared
        return wantsJira && state.hasNotch && !state.islandPlacement.isCorner && GlanceSettings.isOn(.jira)
    }

    /// The island or a card came on screen. No-op while off.
    func refreshIfStale(maxAge: TimeInterval = 5) {
        guard loop != nil, Date().timeIntervalSince(lastRead) > maxAge else { return }
        Task { await read() }
    }

    private func read() async {
        guard wantsBranch || wantsJira, !inFlight, !DemoEngine.isPollerPaused else { return }
        inFlight = true
        lastRead = Date()
        let started = generation
        // Coucou itself in front (Settings, the island): the app used before it.
        var app = NSWorkspace.shared.frontmostApplication
        if app?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            app = AppState.shared.lastExternalApp
        }
        let front = app.flatMap { app in
            app.bundleIdentifier.map { FrontApp(bundleId: $0, pid: app.processIdentifier) }
        }
        let root = DevFlowSettings.reposRoot, pinned = DevFlowSettings.pinnedRepo
        let reader = self.reader
        let queue = self.queue
        let reading: RepoReading = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: reader.read(root: root, pinned: pinned, front: front))
            }
        }
        guard started == generation else { return }
        inFlight = false

        let store = DevFlowStore.shared
        store.repoEditorBundleId = reading.editorBundleId
        store.setIfChanged(\.repo, reading.snapshot)
        store.setIfChanged(\.repoLoaded, true)
        if wantsJira { updateJira(for: reading.snapshot) }
        DevFlowController.shared.syncPills()
    }

    /// The key of the branch, and its status from Jira when credentials are saved.
    private func updateJira(for repo: GitRepoSnapshot?) {
        let store = DevFlowStore.shared
        let key = repo.flatMap { repo in
            repo.detached ? nil : JiraIssueKey.parse(branch: repo.branch, prefix: DevFlowSettings.jiraPrefix)
        }
        store.setIfChanged(\.jiraKey, key)
        // Hidden island: the key only. Jira is asked once the island is back.
        guard AppState.shared.mode != .hidden else { return }
        guard let key,
              let email = KeychainStore.shared.get(DevFlowSettings.jiraEmailKeychainKey), !email.isEmpty,
              let token = KeychainStore.shared.get(DevFlowSettings.jiraTokenKeychainKey), !token.isEmpty else {
            jiraRequest = nil
            store.setIfChanged(\.jira, .noCredentials)
            return
        }
        guard let url = JiraIssueKey.apiURL(site: DevFlowSettings.jiraSite, key: key) else {
            jiraRequest = nil
            store.setIfChanged(\.jira, .badSite)
            return
        }
        let id = url.absoluteString
        if let last = jiraRequest, last.id == id, Date().timeIntervalSince(last.at) < Self.jiraInterval { return }
        if jiraRequest?.id != id { store.setIfChanged(\.jira, .loading) }
        jiraRequest = (id, Date())
        let authorization = JiraIssueKey.authorization(email: email, token: token)
        let started = generation
        Task { [weak self] in
            let result = await JiraClient.fetch(url, authorization: authorization)
            // Dropped if switched off, or if the branch moved to another issue meanwhile.
            guard let self, self.generation == started, self.jiraRequest?.id == id else { return }
            DevFlowStore.shared.setIfChanged(\.jira, result)
        }
    }
}
#endif

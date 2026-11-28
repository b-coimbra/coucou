#if !APPSTORE
import SwiftUI

/// Settings → Integrations → Dev flow: one switch per feature (a pill's switch is the one of
/// Active pills), then Jira and the repositories, saved by their own button.
struct DevFlowSettingsSection: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var edgeLight = EdgeLightSettings.shared
    @AppStorage(DevFlowSettings.ciAlertKey) private var ciAlert = true
    @State private var jiraSite = DevFlowSettings.jiraSite
    @State private var jiraPrefix = DevFlowSettings.jiraPrefix
    @State private var jiraEmail = KeychainStore.shared.get(DevFlowSettings.jiraEmailKeychainKey) ?? ""
    @State private var jiraToken = KeychainStore.shared.get(DevFlowSettings.jiraTokenKeychainKey) ?? ""
    @State private var reposRoot = DevFlowSettings.reposRoot
    @State private var pinnedRepo = DevFlowSettings.pinnedRepo
    @State private var saved = false

    var body: some View {
        GroupBox(String(localized: "devflow.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(String(localized: "devflow.toggle.jira"), isOn: pill(DevFlowPills.jira))
                Toggle(String(localized: "devflow.toggle.prs"), isOn: pill(DevFlowPills.pullRequests))
                Toggle(String(localized: "devflow.toggle.ci"), isOn: $ciAlert)
                    .onChange(of: ciAlert) { _, _ in DevFlowController.shared.apply() }
                caption(String(localized: "devflow.ci.hint"))
                if ciAlert && (!edgeLight.enabled || edgeLight.doNotDisturb) {
                    caption(String(localized: "devflow.ci.edge-light-off"))
                        .foregroundColor(.orange)
                }
                Toggle(String(localized: "devflow.toggle.reviews"), isOn: pill(DevFlowPills.reviews))
                Toggle(String(localized: "devflow.toggle.branch"), isOn: pill(DevFlowPills.branch))
                caption(String(localized: "devflow.github.hint"))

                Divider()
                field(String(localized: "devflow.jira.site"), $jiraSite, prompt: JiraIssueKey.defaultSite)
                field(String(localized: "devflow.jira.prefix"), $jiraPrefix, prompt: JiraIssueKey.defaultPrefix)
                field(String(localized: "devflow.jira.email"), $jiraEmail, prompt: "")
                SecureField(String(localized: "devflow.jira.token"), text: $jiraToken)
                    .textFieldStyle(.roundedBorder)
                caption(String(localized: "devflow.jira.hint"))

                Divider()
                field(String(localized: "devflow.repos.root"), $reposRoot, prompt: DevFlowSettings.defaultReposRoot)
                field(String(localized: "devflow.repos.pinned"), $pinnedRepo, prompt: "")
                caption(String(localized: "devflow.repos.hint"))

                HStack(spacing: 8) {
                    Button(String(localized: "devflow.save")) { save() }
                        .buttonStyle(.borderedProminent)
                    if saved {
                        caption(JiraIssueKey.site(jiraSite) == nil
                                ? String(localized: "devflow.jira.bad-url")
                                : String(localized: "devflow.saved"))
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pill(_ id: String) -> Binding<Bool> {
        Binding(
            get: { state.activeIntegrations.contains(id) },
            set: { on in if on != state.activeIntegrations.contains(id) { state.toggleIntegration(id) } }
        )
    }

    private func field(_ label: String, _ text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: label)
                .font(.system(size: 11))
            TextField("", text: text, prompt: Text(verbatim: prompt))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityLabel(Text(verbatim: label))
        }
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Nothing is sent anywhere while the fields are being typed: only what is saved is used.
    private func save() {
        let defaults = UserDefaults.standard
        let values = [
            (DevFlowSettings.jiraSiteKey, jiraSite), (DevFlowSettings.jiraPrefixKey, jiraPrefix),
            (DevFlowSettings.reposRootKey, reposRoot), (DevFlowSettings.pinnedRepoKey, pinnedRepo),
        ]
        for (key, value) in values {
            defaults.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key)
        }
        keep(DevFlowSettings.jiraEmailKeychainKey, jiraEmail)
        keep(DevFlowSettings.jiraTokenKeychainKey, jiraToken)
        saved = true
        RepoWatcher.shared.settingsChanged()
    }

    private func keep(_ key: String, _ value: String) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            KeychainStore.shared.remove(key)
        } else {
            KeychainStore.shared.set(key, value: text)
        }
    }
}
#endif

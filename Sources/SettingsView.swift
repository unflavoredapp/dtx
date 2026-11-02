import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: RepoStore

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://decrypt.team", text: $store.server)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } header: { Text("Server") } footer: {
                    Text("Builds run on this server. The Studio tab opens it and uses your sign-in there.")
                }
                Section {
                    Button("Reload repos") { Task { await store.refresh() } }
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    LabeledContent("Builds", value: "Unsigned. Sign it with your own certificate to install.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

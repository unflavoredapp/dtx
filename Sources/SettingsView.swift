import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: RepoStore
    @EnvironmentObject var session: Session

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://decrypt.team", text: $store.server)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } header: { Text("Server") } footer: {
                    Text("Decrypting and building run on this server. The app shows its own screens and only talks to the server.")
                }
                Section("Account") {
                    LabeledContent("Signed in as", value: session.username ?? "")
                    LabeledContent("Access", value: "Closed beta (staff)")
                    Button("Sign out", role: .destructive) { Task { await session.signOut() } }
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

import SwiftUI

/// "What's new", read from the server's changelog list. Native, no web page.
struct ChangelogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ChangelogReply.Entry] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !loaded { ProgressView().frame(maxWidth: .infinity).padding(30) }
                    else if entries.isEmpty { Text("Nothing here yet.").foregroundStyle(.secondary) }
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(e.date).font(.caption.weight(.semibold)).foregroundStyle(Color.dtAccent)
                            ForEach(Array(e.items.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("•").foregroundStyle(.secondary)
                                    Text(item).font(.subheadline).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).card()
                    }
                }
                .padding(16)
            }
            .background(Color.dtBG)
            .navigationTitle("Changelog").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .task {
            let r: ChangelogReply? = try? await Api.shared.get("/api/changelog")
            entries = r?.entries ?? []; loaded = true
        }
    }
}

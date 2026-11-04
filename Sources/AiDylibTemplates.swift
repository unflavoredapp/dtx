import SwiftUI

// MARK: - Dylib starter templates

/// Fetched from the server's fixed catalog (dylib-templates.js) — not an AI tool call, just a quick-pick list for
/// someone who doesn't know how to describe what they want yet. Tapping one seeds the chat with a fill-in-the-blank
/// prompt for that kind of dylib; sending it drives the model into propose_dylib_plan / create_dylib as usual, and
/// the template id tags along so the server checks the written files actually do what the template promised.
enum AiDylibTemplate {
    struct Info: Decodable, Identifiable, Equatable {
        var id: String; var name: String; var icon: String; var summary: String
        var frameworks: [String]; var fileLayout: String; var hookApproach: String; var seedPrompt: String
    }
    private struct Reply: Decodable { var templates: [Info] }

    @MainActor static var cached: [Info]?

    static func fetch() async -> [Info] {
        if let c = cached { return c }
        do {
            let r: Reply = try await Api.shared.get("/api/staff/decomp/ai/dylib/templates")
            await MainActor.run { cached = r.templates }
            return r.templates
        } catch { return [] }
    }
}

/// A horizontal row of starter chips, shown above the composer when no project is open yet (or on request). Tapping
/// one fills the draft with that template's seed prompt so the person only has to fill in the blanks, rather than
/// sending immediately — a plan is a bigger ask than a one-line message and deserves a look before it goes out.
struct AiDylibTemplateRow: View {
    let onPick: (AiDylibTemplate.Info) -> Void
    @State private var templates: [AiDylibTemplate.Info] = []

    var body: some View {
        if !templates.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(templates) { t in
                        Button { onPick(t) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: t.icon).font(.caption)
                                Text(t.name).font(.caption.weight(.medium))
                            }
                            .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 7).aiGlass(Capsule())
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .task { templates = await AiDylibTemplate.fetch() }
        } else {
            Color.clear.frame(height: 0).task { templates = await AiDylibTemplate.fetch() }
        }
    }
}

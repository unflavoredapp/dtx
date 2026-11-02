import SwiftUI

/// One app in a list: big icon, name, "version • bundle id", and a small pill. Used by Library and by a source's app list.
struct AppRow: View {
    let app: AppEntry

    var body: some View {
        HStack(spacing: 14) {
            AppIconView(url: app.icon, name: app.name, size: 64)
            VStack(alignment: .leading, spacing: 5) {
                Text(app.name).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text([app.current.map { $0.version }, app.bid].compactMap { $0 }.joined(separator: " • "))
                    .font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                RowPill(text: app.repoName)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").font(.system(size: 18, weight: .bold)).foregroundStyle(Color.dtAccent)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// Small grey capsule with a line of text.
struct RowPill: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.07)))
    }
}

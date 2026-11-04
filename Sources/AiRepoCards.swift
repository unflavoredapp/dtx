import SwiftUI

/// Tappable list of apps from the repo library, shown in the chat after the model runs search_apps.
struct AiAppsCard: View {
    let picks: [AppPick]
    let onPick: (AppPick) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(picks) { pick in
                Button { onPick(pick) } label: {
                    HStack(spacing: 10) {
                        AsyncImage(url: pick.icon) { img in
                            img.resizable()
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08))
                        }
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                        VStack(alignment: .leading, spacing: 1) {
                            Text(pick.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                            Text([pick.developer,
                                  pick.current.map { "v\($0.version)" } ?? "",
                                  pick.versions.count > 1 ? "\(pick.versions.count) versions" : "",
                                  pick.repoName].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.dtLine))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Multi-select list of an app's dylibs/frameworks, with an update banner and the decrypt+reconstruct action.
struct AiLibrariesCard: View {
    let card: LibrariesCard
    let isBusy: Bool
    let onRun: ([LibPick]) -> Void
    let onVersionChange: (AppVersionPick) -> Void

    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if card.versions.count > 1 {
                Menu {
                    ForEach(card.versions) { v in
                        Button {
                            if v.version != card.currentVersion { onVersionChange(v) }
                        } label: {
                            Label("v\(v.version)", systemImage: v.version == card.currentVersion ? "checkmark" : "")
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath").font(.caption)
                        Text("Version v\(card.currentVersion)").font(.caption2.weight(.medium))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Color.dtAccent)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.dtAccent.opacity(0.12)))
                }
            }

            ForEach(card.items) { lib in
                Button { toggle(lib.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selected.contains(lib.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(lib.id) ? Color.dtAccent : .secondary)
                        Image(systemName: lib.type == "framework" ? "square.stack.3d.up.fill" : "cpu.fill")
                            .font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(lib.name).font(.footnote.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                            Text([lib.type, lib.size > 0 ? ByteCountFormatter.string(fromByteCount: lib.size, countStyle: .file) : ""]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected.contains(lib.id) ? Color.dtAccent.opacity(0.5) : Color.dtLine))
                }
                .buttonStyle(.plain)
            }

            Button { onRun(card.items.filter { selected.contains($0.id) }) } label: {
                HStack(spacing: 6) {
                    if isBusy { ProgressView().scaleEffect(0.7).tint(.black) }
                    Image(systemName: "wand.and.stars")
                    Text(selected.isEmpty ? "Select libraries to reconstruct"
                         : "Decrypt & Reconstruct (\(selected.count))")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected.isEmpty || isBusy ? Color.dtAccent.opacity(0.35) : Color.dtAccent))
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty || isBusy)
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}

/// Results of a reconstruction run: each recovered library with a button to download its project zip.
struct AiReconResultsCard: View {
    let results: [ReconResult]
    let onDownload: (ReconResult) -> Void

    @State private var downloading: String?

    var body: some View {
        VStack(spacing: 6) {
            ForEach(results, id: \.dylibName) { r in
                HStack(spacing: 10) {
                    Image(systemName: r.downloadPath != nil ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(r.downloadPath != nil ? Color.dtAccent : .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.dylibName).font(.footnote.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                        Text(r.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if r.downloadPath != nil {
                        Button {
                            downloading = r.dylibName
                            onDownload(r)
                        } label: {
                            if downloading == r.dylibName {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Image(systemName: "square.and.arrow.down").foregroundStyle(Color.dtAccent)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.dtLine))
            }
        }
        .onChange(of: results) { _ in downloading = nil }
    }
}

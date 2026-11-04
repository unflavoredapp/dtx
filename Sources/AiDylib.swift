import SwiftUI

// MARK: - create_dylib: the AI writes a brand-new dylib (plain Objective-C); you review the files, create the project, build it

/// The model supplies the source files only. The server writes them under src/, generates build.sh itself and registers the
/// folder as a project, so Build, edit_code, the build-error fixer and the .dylib/.zip downloads all work on it like on a
/// reconstructed library. Nothing is created until the person taps Create project. Staff only.
enum AiDylibTool {
    static let name = "create_dylib"
    static var available: Bool { UserDefaults.standard.bool(forKey: "dt.me.staff") }

    static let schema: [String: Any] = [
        "type": "function",
        "function": [
            "name": name,
            "description": "Writes a NEW iOS dylib from scratch (a tweak or helper library) as plain Objective-C. Use it when the person wants a new dylib that does something (hook a method, log, patch a value, add a feature to an app). It does NOT create anything: the chat shows the files and the person taps Create project, then Build. Give complete, compilable files. Hook with the Objective-C runtime (objc/runtime.h: method_exchangeImplementations, class_replaceMethod, objc_getClass), start work in an __attribute__((constructor)) function. No Logos (%hook), no Theos, no Swift. Only .m .mm .c .cpp .h files. Do not write a build script: the server generates it.",
            "parameters": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Library name: letters, digits, underscore. Becomes <name>.dylib."],
                    "note": ["type": "string", "description": "One or two lines: what it does and which app/class it targets."],
                    "frameworks": ["type": "array", "items": ["type": "string"], "description": "Extra frameworks to link besides Foundation and UIKit, e.g. AVFoundation."],
                    "template": ["type": "string", "enum": ["method-hook", "ui-overlay", "logger", "settings-panel", "blank"], "description": "If the person picked a starter template (its name appears tagged in their message as [template: id]), pass that id — the server checks the files actually do what that template promises."],
                    "files": ["type": "array", "items": [
                        "type": "object",
                        "properties": ["path": ["type": "string", "description": "e.g. Tweak.m or Hooks/Player.m (relative to src/)"], "content": ["type": "string"]],
                        "required": ["path", "content"],
                    ] as [String: Any]],
                ],
                "required": ["name", "files"],
            ] as [String: Any],
        ] as [String: Any],
    ]

    struct File: Equatable { var path: String; var content: String }

    struct Draft: Equatable {
        var payload: String          // the exact JSON sent to /create
        var name: String
        var frameworks: [String]
        var files: [File]
        var warnings: [String]
        var findings: [Finding]
        var note: String
    }

    /// A severity-leveled review finding ("warn" shown orange, "info" shown gray) rather than a flat warning string.
    struct Finding: Equatable { var severity: String; var message: String }

    static func draft(_ args: [String: Any]) async throws -> Draft {
        let data = try await Api.shared.request("POST", "/api/staff/decomp/ai/dylib/draft", json: args)
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let name = o["name"] as? String else {
            throw ApiError.server("The server's answer wasn't a dylib draft.", 0)
        }
        let files = ((o["files"] as? [[String: Any]]) ?? []).map { File(path: ($0["path"] as? String) ?? "", content: ($0["content"] as? String) ?? "") }
        let findings = ((o["findings"] as? [[String: Any]]) ?? []).map { Finding(severity: ($0["severity"] as? String) ?? "info", message: ($0["message"] as? String) ?? "") }
        var body = args
        body["files"] = files.map { ["path": $0.path, "content": $0.content] }
        let payload = (try? JSONSerialization.data(withJSONObject: body)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return Draft(payload: payload, name: name, frameworks: (o["frameworks"] as? [String]) ?? [], files: files,
                     warnings: (o["warnings"] as? [String]) ?? [], findings: findings, note: (args["note"] as? String) ?? "")
    }

    static func create(_ d: Draft) async throws -> String {
        let body = (d.payload.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let data = try await Api.shared.request("POST", "/api/staff/decomp/ai/dylib/create", json: body)
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = o["jobID"] as? String else {
            throw ApiError.server("The server didn't create the project.", 0)
        }
        return id
    }
}

extension AiDecryptViewModel {
    func proposeDylib(arguments: String, into index: Int) async -> String {
        guard let d = arguments.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], !o.isEmpty else {
            return "The create_dylib arguments were not valid JSON. Try again with name and files."
        }
        do {
            let draft = try await AiDylibTool.draft(o)
            guard index < messages.count else { return "Cancelled." }
            if messages[index].content.hasPrefix("Running ") { messages[index].content = "" }
            messages[index].card = .dylibDraft(draft)
            messages[index].toolCalls = nil
            return "A draft of \(draft.name).dylib (\(draft.files.count) file(s)) is on screen. NOTHING exists yet: the person taps Create project, then Build. Say in one or two lines what it does and how it hooks in; don't paste the code again." +
                (draft.warnings.isEmpty ? "" : " Server warnings: " + draft.warnings.joined(separator: " | "))
        } catch {
            return "The dylib was rejected: \(error.localizedDescription). Fix that and call create_dylib again if the person still wants it; nothing was created."
        }
    }

    func setCard(messageID: UUID, _ card: AiCard) {
        if let i = messages.firstIndex(where: { $0.id == messageID }) { messages[i].card = card }
    }
}

// MARK: - Draft card

struct AiDylibDraftCard: View {
    let draft: AiDylibTool.Draft
    let onCreated: (String) -> Void
    @State private var open: Set<String> = []
    @State private var working = false
    @State private var error: String?
    @State private var dismissed = false

    var body: some View {
        if dismissed {
            Label("Draft discarded. Nothing was created.", systemImage: "xmark.circle").font(.footnote).foregroundStyle(.secondary).padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox").foregroundStyle(Color.dtAccent)
                    Text("\(draft.name).dylib").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    Spacer(minLength: 0)
                    Text("NEW").font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Color.dtAccent.opacity(0.25))).foregroundStyle(Color.dtAccent)
                }
                if !draft.note.isEmpty { Text(draft.note).font(.footnote).foregroundStyle(.white.opacity(0.8)) }
                Text("Links: " + draft.frameworks.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                ForEach(draft.files, id: \.path) { f in
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            if open.contains(f.path) { open.remove(f.path) } else { open.insert(f.path) }
                        } label: {
                            HStack {
                                Image(systemName: open.contains(f.path) ? "chevron.down" : "chevron.right").font(.caption2)
                                Text("src/" + f.path).font(.footnote.monospaced())
                                Spacer(minLength: 0)
                                Text("\(f.content.split(separator: "\n", omittingEmptySubsequences: false).count) lines").font(.caption2).foregroundStyle(.secondary)
                            }.foregroundStyle(.white)
                        }.buttonStyle(.plain)
                        if open.contains(f.path) {
                            ScrollView(.horizontal) {
                                Text(f.content).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.9)).textSelection(.enabled)
                                    .padding(8)
                            }.frame(maxHeight: 280).background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
                        }
                    }
                }
                ForEach(Array(draft.findings.enumerated()), id: \.offset) { _, f in
                    Label(f.message, systemImage: f.severity == "warn" ? "exclamationmark.triangle" : "info.circle")
                        .font(.caption).foregroundStyle(f.severity == "warn" ? .orange : .secondary)
                }
                if let e = error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(6) }
                HStack(spacing: 8) {
                    if working { ProgressView().scaleEffect(0.8) }
                    Button { Task { await create() } } label: {
                        Label("Create project", systemImage: "plus").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.dtOnAccent).padding(.horizontal, 16).padding(.vertical, 9).background(Capsule().fill(Color.dtAccent))
                    }.disabled(working)
                    Button { dismissed = true } label: {
                        Text("Discard").font(.system(size: 15, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 9).aiGlass(Capsule())
                    }.disabled(working)
                }
            }
            .padding(12)
        }
    }

    private func create() async {
        working = true; error = nil; defer { working = false }
        do { onCreated(try await AiDylibTool.create(draft)) } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Created project card: Build, auto-fix, share

struct AiAuthoredCard: View {
    let jobID: String
    let name: String
    @State private var building = false
    @State private var buildLine = ""
    @State private var buildLog = ""
    @State private var built: String?
    @State private var error: String?
    @State private var fixing = false
    @State private var fixPatchID: String?
    @State private var fixReply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill").foregroundStyle(Color.dtAccent)
                Text("\(name).dylib project created").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            if fixing { HStack(spacing: 8) { ProgressView().scaleEffect(0.8); Text(buildLine.isEmpty ? "Build failed. Working out a fix…" : buildLine).font(.caption).foregroundStyle(.secondary) } }
            if let f = fixPatchID {
                if !fixReply.isEmpty { Text(fixReply).font(.footnote).foregroundStyle(.white.opacity(0.85)) }
                AiPatchCard(jobID: jobID, patchID: f, name: name, depth: 1, autoBuild: true).id(f)
            }
            if building { Text(buildLine.isEmpty ? "Starting the build…" : buildLine).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2) }
            if let b = built {
                HStack(spacing: 8) {
                    Label("Built", systemImage: "checkmark.seal.fill").font(.footnote.bold()).foregroundStyle(Color.dtAccent)
                    Spacer(minLength: 0)
                    Button { Task { await share(ReconstructAPI.dylibDownloadPath(jobID: jobID), b) } } label: {
                        Text(".dylib").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 7).aiGlass(Capsule())
                    }
                    Button { Task { await share(ReconstructAPI.zipDownloadPath(jobID: jobID), name + "-project.zip") } } label: {
                        Text("Project .zip").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 7).aiGlass(Capsule())
                    }
                }
            }
            if let e = error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(8) }
            HStack(spacing: 8) {
                Button { Task { await build() } } label: {
                    Label(built == nil ? "Build" : "Rebuild", systemImage: "hammer.fill").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.dtOnAccent).padding(.horizontal, 16).padding(.vertical, 9).background(Capsule().fill(Color.dtAccent))
                }.disabled(building || fixing)
                Button { ReconEditorPresenter.present(jobID: jobID, dylibName: name) } label: {
                    Label("Open editor", systemImage: "chevron.left.forwardslash.chevron.right").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 9).aiGlass(Capsule())
                }
            }
        }
        .padding(12)
    }

    private func build() async {
        building = true; error = nil; buildLine = ""; buildLog = ""; fixPatchID = nil; defer { building = false }
        do { built = try await ReconstructAPI.build(jobID: jobID) { line in buildLine = line; buildLog += line + "\n" } }
        catch { self.error = "Build failed: " + error.localizedDescription; await fix(error.localizedDescription) }
    }

    private func fix(_ why: String) async {
        guard !fixing else { return }
        fixing = true; defer { fixing = false }
        let ask = "The build failed. Fix the compiler/linker errors with a real, minimal correction that keeps the intended behaviour: do not delete the feature, comment code out or silence warnings just to compile. Explain the cause in the reply.\n\nBuild output:\n\(why)\n\(String(buildLog.suffix(1800)))"
        do {
            let r = try await ReconstructAPI.aiAsk(jobID: jobID, message: ask, action: "fix", file: nil, symbol: nil, selection: nil, selectionLine: nil,
                                                  onStart: { _ in }, progress: { p in buildLine = "Writing a fix… \(p.tokens) tokens" })
            fixReply = r.reply
            if let fp = r.patch { fixPatchID = fp.id } else { error = "Build failed, and no safe fix was found: " + r.reply }
        } catch { error = "Build failed, and the fix request failed: " + error.localizedDescription }
        buildLine = ""
    }

    private func share(_ path: String, _ file: String) async {
        do { SharePresenter.present(try await FileDownloader().download(path: path, name: file) { _ in }) }
        catch { self.error = error.localizedDescription }
    }
}

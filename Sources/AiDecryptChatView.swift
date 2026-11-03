//
//  AiDecryptChatView.swift
//  Decrypt.Team
//
//  Native chat screen for the Ai-Decrypt assistant, matching the app's
//  existing dark/lime theme (Theme.swift) and Api.shared conventions.
//  Talks to the llama.cpp OpenAI-compatible endpoint, proxied through
//  Apache at https://ai.decrypt.team/v1/chat/completions.
//
//  Three extra capabilities on top of plain chat:
//  - Attaching a .zip/.ipa/.dylib gives the model function-calling access to the app's bundled
//    analysis tools (see AiToolBridge.swift and Tools/LocalZip.swift).
//  - Attaching a photo routes the turn to a vision-capable model/endpoint (see AiDecryptAPI.visionEndpoint)
//    so the model can look at screenshots, mockups, or a photo of an error.
//  - The model can call `generate_image` at any time (see AiImageGen.swift) to make and show a picture.
//

import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import UIKit

// MARK: - Model

struct AiToolCallResult: Equatable {
    let id: String
    let name: String
    /// Raw (and, mid-stream, possibly partial) JSON text of the call's arguments, e.g. {"prompt":"..."}.
    let arguments: String
}

struct AiChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant, system, tool }
    let id = UUID()
    let role: Role
    var content: String
    /// A photo the person attached (role .user) or a picture the model generated via `generate_image`
    /// (role .assistant) — either way, shown inline under this message's bubble.
    var imageData: Data? = nil
    /// Set on an assistant message that asked to call one or more tools.
    var toolCalls: [AiToolCallResult]? = nil
    /// Set on a `tool` message: which call this is the result of.
    var toolCallId: String? = nil
    var name: String? = nil
}

struct AiAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let content: String
}

/// A .zip/.ipa/.dylib attached straight into the chat, saved to a temp file so the bundled Tools can read it
/// (see Tools/LocalZip.swift) without needing an https link anywhere.
struct AiBinaryAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let fileURL: URL
    let size: Int
}

struct AiImageAttachment: Identifiable, Equatable {
    let id = UUID()
    let data: Data
}

// MARK: - API client

enum AiDecryptAPI {
    static let endpoint = URL(string: "https://ai.decrypt.team/v1/chat/completions")!
    static let model = "AiDecrypt"

    /// A second llama-server instance running a vision-capable model (Qwen2-VL or similar, loaded with
    /// --mmproj), proxied at its own path so the text model's endpoint above doesn't have to change.
    static let visionEndpoint = URL(string: "https://ai.decrypt.team/v1vision/chat/completions")!
    static let visionModel = "AiDecryptVision"

    /// Streams the assistant's reply token-by-token (`onDelta`, called on the main actor) and returns any
    /// tool calls the model asked for once the stream ends. `tools` is the OpenAI-style function list —
    /// pass nil/empty when there's nothing for the model to call.
    ///
    /// Without an explicit max_tokens, llama.cpp falls back to its own low default and cuts replies off
    /// mid-sentence (finish_reason "length") — 4096 gives it real room.
    @discardableResult
    static func streamChat(
        messages: [AiChatMessage],
        tools: [[String: Any]]? = nil,
        endpoint: URL = AiDecryptAPI.endpoint,
        model: String = AiDecryptAPI.model,
        onDelta: @escaping (String) -> Void
    ) async throws -> [AiToolCallResult] {
        var request = URLRequest(url: endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { m -> [String: Any] in
                var d: [String: Any] = ["role": m.role.rawValue]
                if let name = m.name { d["name"] = name }
                if let tcId = m.toolCallId { d["tool_call_id"] = tcId }
                if let calls = m.toolCalls, !calls.isEmpty {
                    d["tool_calls"] = calls.map {
                        ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments.isEmpty ? "{}" : $0.arguments]]
                    }
                }
                if let img = m.imageData {
                    // OpenAI vision format: content becomes an array of text/image_url parts instead of a plain string.
                    var parts: [[String: Any]] = []
                    if !m.content.isEmpty { parts.append(["type": "text", "text": m.content]) }
                    parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + img.base64EncodedString()]])
                    d["content"] = parts
                } else {
                    d["content"] = m.content
                }
                return d
            },
            "stream": true,
            "max_tokens": 4096,
        ]
        if let tools, !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = "auto" }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ApiError.server("The model server answered with error \(code).", code)
        }

        var callsByIndex: [Int: (id: String, name: String, arguments: String)] = [:]
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any]
            else { continue }

            if let content = delta["content"] as? String, !content.isEmpty {
                await MainActor.run { onDelta(content) }
            }
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for tc in toolCalls {
                    let idx = tc["index"] as? Int ?? 0
                    var entry = callsByIndex[idx] ?? (id: "", name: "", arguments: "")
                    if let id = tc["id"] as? String, !id.isEmpty { entry.id = id }
                    if let fn = tc["function"] as? [String: Any] {
                        if let name = fn["name"] as? String, !name.isEmpty { entry.name = name }
                        if let args = fn["arguments"] as? String { entry.arguments += args }
                    }
                    callsByIndex[idx] = entry
                }
            }
        }
        return callsByIndex.values.filter { !$0.name.isEmpty }
            .map { AiToolCallResult(id: $0.id.isEmpty ? UUID().uuidString : $0.id, name: $0.name, arguments: $0.arguments) }
    }
}

// MARK: - View model

@MainActor
final class AiDecryptViewModel: ObservableObject {
    @Published var messages: [AiChatMessage] = []
    @Published var draft = ""
    @Published var isStreaming = false
    @Published var errorText: String?
    @Published var pendingAttachments: [AiAttachment] = []
    @Published var binaryAttachment: AiBinaryAttachment?
    @Published var pendingImage: AiImageAttachment?
    @Published var isFetchingWebpage = false

    private var streamTask: Task<Void, Never>?
    private var pendingAppend = ""
    private var flushTask: Task<Void, Never>?

    func addFile(name: String, content: String) {
        pendingAttachments.append(AiAttachment(name: name, content: content))
    }

    func removeAttachment(_ attachment: AiAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    /// A .zip/.ipa/.dylib attached in chat: copied to a temp file so the bundled Tools (LocalZip) can read it,
    /// and kept around across turns so the model can call tools on it again later in the same conversation.
    func addBinaryFile(name: String, data: Data) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ai-decrypt-attach", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = name.isEmpty ? "attachment" : name
        let dest = dir.appendingPathComponent(UUID().uuidString + "-" + safeName)
        do {
            try data.write(to: dest)
            removeBinaryAttachment()
            binaryAttachment = AiBinaryAttachment(name: safeName, fileURL: dest, size: data.count)
        } catch {
            errorText = "Couldn't attach \(safeName): \(error.localizedDescription)"
        }
    }

    func removeBinaryAttachment() {
        if let b = binaryAttachment { try? FileManager.default.removeItem(at: b.fileURL) }
        binaryAttachment = nil
    }

    /// A photo for the vision model to look at. Downscaled first — the CPU-bound vision pass only gets
    /// slower for no benefit past ~1024px, and it keeps the base64 payload reasonable.
    func setImage(_ data: Data) {
        pendingImage = AiImageAttachment(data: Self.downscaled(data))
    }

    func removeImage() { pendingImage = nil }

    private static func downscaled(_ data: Data, maxDim: CGFloat = 1024) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let scale = min(1, maxDim / max(image.size.width, image.size.height))
        guard scale < 1 else { return image.jpegData(compressionQuality: 0.85) ?? data }
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: 0.8) ?? data
    }

    func attachWebpage(_ urlString: String) {
        var urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlString.lowercased().hasPrefix("http") { urlString = "https://" + urlString }
        guard let url = URL(string: urlString) else {
            errorText = "That doesn't look like a valid URL."
            return
        }
        isFetchingWebpage = true
        Task {
            defer { isFetchingWebpage = false }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let html = String(data: data, encoding: .utf8) ?? ""
                let text = Self.stripHTML(html)
                let truncated = text.count > 6000 ? String(text.prefix(6000)) + "\n…(truncated)" : text
                addFile(name: url.host ?? urlString, content: truncated)
            } catch {
                errorText = "Couldn't fetch that page: \(error.localizedDescription)"
            }
        }
    }

    private static func stripHTML(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty || binaryAttachment != nil || pendingImage != nil, !isStreaming else { return }

        var fullText = text
        if !pendingAttachments.isEmpty {
            let blocks = pendingAttachments.map { "--- file: \($0.name) ---\n\($0.content)\n" }.joined(separator: "\n")
            fullText = blocks + (text.isEmpty ? "" : "\n" + text)
        }
        pendingAttachments = []

        var userMessage = AiChatMessage(role: .user, content: fullText)
        userMessage.imageData = pendingImage?.data
        pendingImage = nil
        messages.append(userMessage)

        draft = ""
        errorText = nil
        isStreaming = true
        streamTask = Task { await self.runTurn() }
    }

    func cancel() { streamTask?.cancel(); isStreaming = false }

    func newChat() { cancel(); messages = []; errorText = nil; removeBinaryAttachment(); removeImage() }

    /// A system message describing the attached file and available tools, prepended ahead of the real
    /// transcript on every request — never stored in `messages`, so it doesn't show up in the UI.
    private func apiMessages(upTo index: Int) -> [AiChatMessage] {
        var out: [AiChatMessage] = []
        if let bin = binaryAttachment {
            out.append(AiChatMessage(role: .system, content:
                "A file named \"\(bin.name)\" is attached in this chat. You have tools to analyze it directly " +
                "(app_info, package, raw_plist, link_check, binary, bundles, privacy) — call whichever ones help " +
                "answer the person. You don't need a link or any other input; they already operate on the attached file."
            ))
        }
        out += Array(messages.prefix(index))
        return out
    }

    /// One assistant turn, following any tool calls it makes until it gives a normal reply (or a small loop cap is hit).
    /// A turn whose history includes a photo is routed to the vision model/endpoint instead of the text one.
    private func runTurn() async {
        let usesVision = messages.contains { $0.imageData != nil }
        var loops = 0
        while loops < 4 {
            loops += 1
            let assistantIndex = messages.count
            messages.append(AiChatMessage(role: .assistant, content: ""))
            do {
                var tools: [[String: Any]] = [AiImageGen.schema]
                if !usesVision, binaryAttachment != nil { tools += AiToolBridge.toolSchemas() }

                let calls = try await AiDecryptAPI.streamChat(
                    messages: apiMessages(upTo: assistantIndex),
                    tools: tools,
                    endpoint: usesVision ? AiDecryptAPI.visionEndpoint : AiDecryptAPI.endpoint,
                    model: usesVision ? AiDecryptAPI.visionModel : AiDecryptAPI.model
                ) { [weak self] delta in self?.appendThrottled(delta, at: assistantIndex) }
                flushNow(at: assistantIndex)

                guard !calls.isEmpty else { break }
                messages[assistantIndex].toolCalls = calls
                if messages[assistantIndex].content.isEmpty {
                    let names = calls.map { $0.name.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")
                    messages[assistantIndex].content = "Running \(names)…"
                }

                for call in calls {
                    if call.name == "generate_image" {
                        let prompt = AiImageGen.extractPrompt(call.arguments)
                        do {
                            let imgData = try await AiImageGen.generate(prompt: prompt)
                            messages[assistantIndex].imageData = imgData
                            messages.append(AiChatMessage(role: .tool, content: "Image generated and shown to the person.", toolCallId: call.id, name: call.name))
                        } catch {
                            messages.append(AiChatMessage(role: .tool, content: "Image generation failed: \(error.localizedDescription)", toolCallId: call.id, name: call.name))
                        }
                    } else if let bin = binaryAttachment, let tool = AiToolBridge.tool(named: call.name) {
                        let resultText = await AiToolBridge.run(tool, fileURL: bin.fileURL)
                        messages.append(AiChatMessage(role: .tool, content: resultText, toolCallId: call.id, name: call.name))
                    } else {
                        messages.append(AiChatMessage(role: .tool, content: "Unknown tool \"\(call.name)\".", toolCallId: call.id, name: call.name))
                    }
                }
                // loop again so the model sees the tool results and can reply or call another tool
            } catch {
                errorText = error.localizedDescription
                break
            }
        }
        isStreaming = false
    }

    /// Batches token deltas and flushes at ~10fps instead of re-rendering on every token.
    private func appendThrottled(_ delta: String, at index: Int) {
        pendingAppend += delta
        if flushTask == nil {
            flushTask = Task {
                try? await Task.sleep(nanoseconds: 100_000_000)
                flushNow(at: index)
                flushTask = nil
            }
        }
    }

    private func flushNow(at index: Int) {
        guard !pendingAppend.isEmpty, index < messages.count else { return }
        messages[index].content += pendingAppend
        pendingAppend = ""
    }
}

// MARK: - Chat view

struct AiDecryptChatView: View {
    @StateObject private var viewModel = AiDecryptViewModel()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool
    @State private var showWebpageAlert = false
    @State private var webpageURL = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Each presentation modifier is attached to a DIFFERENT subview on purpose. SwiftUI does not
                // reliably honor several presentation modifiers (.fileImporter / .photosPicker / .alert) stacked
                // on one view — especially when that view is itself inside a .sheet, as this whole screen is.
                // Only one tends to win and the others silently never present or never fire their callback.
                // Spreading them across messageList / composer / the outer view keeps all three working.
                messageList
                    .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
                    .onChange(of: photoItem) { _ in handlePickedPhoto() }
                if let error = viewModel.errorText { errorBanner(error) }
                if !viewModel.pendingAttachments.isEmpty || viewModel.binaryAttachment != nil || viewModel.pendingImage != nil { attachmentChips }
                composer
            }
            .background(AppBackground())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Label("Ai-Decrypt", systemImage: "message.fill").labelStyle(OrangeIcon())
                        .font(.headline).foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { viewModel.newChat() } label: { Image(systemName: "square.and.pencil") }
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert("Attach webpage", isPresented: $showWebpageAlert) {
            TextField("https://example.com", text: $webpageURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Cancel", role: .cancel) { webpageURL = "" }
            Button("Attach") { viewModel.attachWebpage(webpageURL); webpageURL = "" }
        } message: {
            Text("Its text content will be added as context for your next message.")
        }
    }

    private func pickFiles() {
        DocumentPickerPresenter.pickFiles(
            types: [.plainText, .sourceCode, .json, .zip, UTType(filenameExtension: "dylib") ?? .data, .data]
        ) { handlePickedDocuments($0) }
    }

    private func handlePickedDocuments(_ urls: [URL]) {
        if urls.isEmpty { viewModel.errorText = "No file came back from the picker." }
        for url in urls {
            // asCopy: true already placed a readable copy in our temp dir, so no security-scope / coordinator needed.
            do {
                let data = try Data(contentsOf: url)
                guard !data.isEmpty else { throw ZipError("That file came back empty.") }
                let ext = url.pathExtension.lowercased()
                if ext == "zip" || ext == "ipa" || ext == "dylib" || String(data: data, encoding: .utf8) == nil {
                    // a zip/IPA/dylib (or anything else that isn't plain text): give it to the tool system, not the prompt text
                    viewModel.addBinaryFile(name: url.lastPathComponent, data: data)
                } else if let text = String(data: data, encoding: .utf8) {
                    viewModel.addFile(name: url.lastPathComponent, content: text)
                }
            } catch {
                viewModel.errorText = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private func handlePickedPhoto() {
        guard let item = photoItem else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                viewModel.errorText = "Couldn't load that photo."
                photoItem = nil
                return
            }
            viewModel.setImage(data)
            photoItem = nil
        }
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let bin = viewModel.binaryAttachment {
                    HStack(spacing: 6) {
                        Image(systemName: "shippingbox.fill").font(.caption2)
                        Text(bin.name).font(.caption2).lineLimit(1)
                        Button { viewModel.removeBinaryAttachment() } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                    }
                    .foregroundStyle(Color.dtAccent)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .glowCapsule(strong: true)
                }
                if let img = viewModel.pendingImage, let ui = UIImage(data: img.data) {
                    HStack(spacing: 6) {
                        Image(uiImage: ui).resizable().scaledToFill()
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        Text("Photo").font(.caption2)
                        Button { viewModel.removeImage() } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .glowCapsule()
                }
                ForEach(viewModel.pendingAttachments) { att in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").font(.caption2)
                        Text(att.name).font(.caption2).lineLimit(1)
                        Button { viewModel.removeAttachment(att) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .glowCapsule()
                }
                if viewModel.isFetchingWebpage {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 6)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.messages.filter { $0.role == .user || $0.role == .assistant }) { message in
                        AiMessageBubble(message: message).id(message.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: viewModel.messages.last?.content) { _ in
                guard let last = viewModel.messages.last(where: { $0.role == .user || $0.role == .assistant }) else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(.red)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.1))
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Menu {
                Button { pickFiles() } label: { Label("Upload files", systemImage: "paperclip") }
                Button { showPhotoPicker = true } label: { Label("Attach photo", systemImage: "photo") }
                Button { showWebpageAlert = true } label: { Label("Attach webpage", systemImage: "globe") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }

            TextField("Message Ai-Decrypt...", text: $viewModel.draft, axis: .vertical)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .glowCapsule()

            Button {
                inputFocused = false
                viewModel.isStreaming ? viewModel.cancel() : viewModel.send()
            } label: {
                Image(systemName: viewModel.isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.dtAccent))
            }
            .disabled(
                viewModel.draft.trimmingCharacters(in: .whitespaces).isEmpty
                    && viewModel.pendingAttachments.isEmpty
                    && viewModel.binaryAttachment == nil
                    && viewModel.pendingImage == nil
                    && !viewModel.isStreaming
            )
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .overlay(Divider().overlay(Color.dtLine), alignment: .top)
    }
}

// MARK: - Message bubble

private struct AiMessageBubble: View {
    let message: AiChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 6) {
                if let data = message.imageData, let ui = UIImage(data: data) {
                    Image(uiImage: ui).resizable().scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                ForEach(Array(contentBlocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let text):
                        Text(text).font(.subheadline).foregroundStyle(.white).textSelection(.enabled)
                    case .code(let lang, let code):
                        AiCodeBlockView(language: lang, code: code).padding(.vertical, 4)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(message.role == .user ? Color.dtAccent.opacity(0.14) : Color.white.opacity(0.065))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(message.role == .user ? Color.dtAccent.opacity(0.4) : Color.white.opacity(0.1))
            )
            if message.role == .assistant { Spacer(minLength: 32) }
        }
    }

    private enum Block { case text(String); case code(lang: String, code: String) }

    private var contentBlocks: [Block] {
        var blocks: [Block] = []
        let parts = message.content.components(separatedBy: "```")
        for (i, part) in parts.enumerated() {
            if i % 2 == 0 {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { blocks.append(.text(trimmed)) }
            } else {
                var lines = part.components(separatedBy: "\n")
                let lang = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
                if !lines.isEmpty { lines.removeFirst() }
                blocks.append(.code(lang: lang, code: lines.joined(separator: "\n").trimmingCharacters(in: .newlines)))
            }
        }
        if blocks.isEmpty && !message.content.isEmpty { blocks.append(.text(message.content)) }
        return blocks
    }
}

private struct AiCodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Text(copied ? "Copied" : "Copy").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.03))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.dtGreen).padding(8)
            }
        }
        .background(Color.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.dtLine))
    }
}

#Preview {
    AiDecryptChatView()
}

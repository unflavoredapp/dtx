//
//  AiDecryptChatView.swift
//  Decrypt.Team
//
//  Native chat screen for the Ai-Decrypt assistant, matching the app's
//  existing dark/lime theme (Theme.swift) and Api.shared conventions.
//  Talks to the llama.cpp OpenAI-compatible endpoint, proxied through
//  Apache at https://ai.decrypt.team/v1/chat/completions.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

struct AiChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }
    let id = UUID()
    let role: Role
    var content: String
}

struct AiAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let content: String
}

// MARK: - API client

enum AiDecryptAPI {
    static let endpoint = URL(string: "https://ai.decrypt.team/v1/chat/completions")!
    static let model = "AiDecrypt"

    private struct RequestBody: Encodable {
        let model: String
        let messages: [[String: String]]
        let stream: Bool
    }

    /// Streams the assistant's reply token-by-token. `onDelta` is called on the main actor.
    static func streamChat(messages: [AiChatMessage], onDelta: @escaping (String) -> Void) async throws {
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                model: model,
                messages: messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                stream: true
            )
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ApiError.server("The model server answered with error \(code).", code)
        }

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String, !content.isEmpty
            else { continue }
            await MainActor.run { onDelta(content) }
        }
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
        guard !text.isEmpty || !pendingAttachments.isEmpty, !isStreaming else { return }

        var fullText = text
        if !pendingAttachments.isEmpty {
            let blocks = pendingAttachments.map { "--- file: \($0.name) ---\n\($0.content)\n" }.joined(separator: "\n")
            fullText = blocks + (text.isEmpty ? "" : "\n" + text)
        }
        pendingAttachments = []

        messages.append(AiChatMessage(role: .user, content: fullText))
        draft = ""
        errorText = nil

        let assistantIndex = messages.count
        messages.append(AiChatMessage(role: .assistant, content: ""))
        isStreaming = true

        streamTask = Task {
            do {
                try await AiDecryptAPI.streamChat(messages: Array(messages.prefix(assistantIndex))) { [weak self] delta in
                    self?.appendThrottled(delta, at: assistantIndex)
                }
            } catch {
                errorText = error.localizedDescription
            }
            flushNow(at: assistantIndex)
            isStreaming = false
        }
    }

    func cancel() { streamTask?.cancel(); isStreaming = false }

    func newChat() { cancel(); messages = []; errorText = nil }

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
    @State private var showFilePicker = false
    @State private var showWebpageAlert = false
    @State private var webpageURL = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList
                if let error = viewModel.errorText { errorBanner(error) }
                if !viewModel.pendingAttachments.isEmpty { attachmentChips }
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
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.plainText, .sourceCode, .json, .item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                    viewModel.addFile(name: url.lastPathComponent, content: text)
                }
            }
        }
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

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
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
                    ForEach(viewModel.messages) { message in
                        AiMessageBubble(message: message).id(message.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: viewModel.messages.last?.content) { _ in
                guard let last = viewModel.messages.last else { return }
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
                Button { showFilePicker = true } label: { Label("Upload files", systemImage: "paperclip") }
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
            .disabled(viewModel.draft.trimmingCharacters(in: .whitespaces).isEmpty && viewModel.pendingAttachments.isEmpty && !viewModel.isStreaming)
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
            VStack(alignment: .leading, spacing: 0) {
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
        if blocks.isEmpty { blocks.append(.text(message.content)) }
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

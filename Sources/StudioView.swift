import SwiftUI
import WebKit

/// The website's Studio, inside the app. It shares the website's own sign-in and does the real work on the server.
struct StudioView: View {
    @EnvironmentObject var store: RepoStore
    @StateObject private var model = WebModel()

    var body: some View {
        ZStack(alignment: .top) {
            WebView(model: model)
                .ignoresSafeArea(edges: .bottom)
            if model.progress < 1 { ProgressView(value: model.progress).tint(.orange) }
        }
        .onAppear { model.load(server: store.server, path: store.studioPath) }
        .onChange(of: store.studioPath) { model.load(server: store.server, path: $0) }
        .onChange(of: store.server) { model.load(server: $0, path: store.studioPath) }
    }
}

final class WebModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    @Published var progress: Double = 1
    let web: WKWebView
    private var loaded = ""
    private var observer: NSKeyValueObservation?
    private var downloadDest: URL?

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        observer = web.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
            DispatchQueue.main.async { self?.progress = w.isLoading ? w.estimatedProgress : 1 }
        }
    }

    func load(server: String, path: String) {
        let base = server.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + path), url.scheme == "https" else { return }
        if loaded == url.absoluteString { return }
        loaded = url.absoluteString
        web.load(URLRequest(url: url))
    }

    // Links to other apps (sideloaders, Telegram…) open outside; everything else stays in the page.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        if let u = navigationAction.request.url, let s = u.scheme?.lowercased(), !["http", "https", "about", "blob", "data"].contains(s) {
            UIApplication.shared.open(u); decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let attach = ((navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? "")
            .lowercased().contains("attachment")
        decisionHandler(attach || !navigationResponse.canShowMIMEType ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let u = navigationAction.request.url {
            if u.scheme == "https" && (u.host ?? "") == web.url?.host { webView.load(navigationAction.request) } else { UIApplication.shared.open(u) }
        }
        return nil
    }

    // MARK: downloads → Files / share sheet

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = suggestedFilename.replacingOccurrences(of: "/", with: "_")
        let dest = dir.appendingPathComponent(name.isEmpty ? "download.ipa" : name)
        downloadDest = dest
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloadDest else { return }
        DispatchQueue.main.async {
            let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            let root = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
            var top = root; while let p = top?.presentedViewController { top = p }
            vc.popoverPresentationController?.sourceView = top?.view
            top?.present(vc, animated: true)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {}
}

struct WebView: UIViewRepresentable {
    @ObservedObject var model: WebModel
    func makeUIView(context: Context) -> WKWebView { model.web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

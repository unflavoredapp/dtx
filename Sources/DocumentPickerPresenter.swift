import UIKit
import UniformTypeIdentifiers

/// Imperative document picker, matching the pattern AirShare uses. Presents a UIDocumentPickerViewController
/// directly on the top-most view controller rather than through a SwiftUI `.sheet`/`.fileImporter`, which is
/// what makes it reliable inside an already-presented sheet (SwiftUI drops stacked presentations; this doesn't).
///
/// `asCopy: true` hands back URLs that are copies in the app's own temp dir, so they're readable immediately
/// with `Data(contentsOf:)` — no security-scoped-resource access or file coordinator needed.
enum DocumentPickerPresenter {
    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish([]) }
        private func finish(_ urls: [URL]) {
            onPick(urls)
            DocumentPickerPresenter.retained = nil   // release self now that the pick is done
        }
    }

    /// The delegate must outlive the picker's presentation; SwiftUI won't hold it, so we do.
    private static var retained: Delegate?

    static func pickFiles(types: [UTType] = [.data], allowsMultiple: Bool = true, asCopy: Bool = true, completion: @escaping ([URL]) -> Void) {
        present(types: types, allowsMultiple: allowsMultiple, asCopy: asCopy, completion: completion)
    }

    static func pickAudio(completion: @escaping (URL?) -> Void) {
        present(types: [.audio], allowsMultiple: false, asCopy: true) { completion($0.first) }
    }

    private static func present(types: [UTType], allowsMultiple: Bool, asCopy: Bool, completion: @escaping ([URL]) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        picker.allowsMultipleSelection = allowsMultiple
        let delegate = Delegate(onPick: completion)
        picker.delegate = delegate
        retained = delegate
        guard let top = topViewController() else { completion([]); retained = nil; return }
        top.present(picker, animated: true)
    }

    static func topViewController() -> UIViewController? {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// Presents a share sheet (UIActivityViewController) imperatively on the top-most controller — same reason as
/// the document picker: it works reliably on top of the already-presented Ai-Decrypt sheet.
enum SharePresenter {
    static func present(_ url: URL) {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let top = DocumentPickerPresenter.topViewController() else { return }
        vc.popoverPresentationController?.sourceView = top.view
        vc.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        top.present(vc, animated: true)
    }
}

import SwiftUI

extension View {
    /// Drop-in replacement for `.fileImporter` that uses the UIKit picker (works inside full-screen covers and sheets).
    func filePicker(isPresented: Binding<Bool>, types: [UTType] = [.data], multiple: Bool = false, asCopy: Bool = true,
                    onPick: @escaping ([URL]) -> Void) -> some View {
        onChange(of: isPresented.wrappedValue) { on in
            guard on else { return }
            isPresented.wrappedValue = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                DocumentPickerPresenter.pickFiles(types: types, allowsMultiple: multiple, asCopy: asCopy) { urls in
                    if !urls.isEmpty { onPick(urls) }
                }
            }
        }
    }
}

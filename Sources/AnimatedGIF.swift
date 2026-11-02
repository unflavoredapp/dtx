import SwiftUI
import UIKit
import ImageIO

/// Plays a GIF bundled with the app (e.g. "delvek" for Resources/delvek.gif), looping, at its own frame timing.
struct AnimatedGIF: UIViewRepresentable {
    let name: String

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.image = AnimatedGIF.load(name)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {}

    private static var cache: [String: UIImage] = [:]

    static func load(_ name: String) -> UIImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: "gif"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var frames: [UIImage] = []
        var total = 0.0
        for i in 0..<CGImageSourceGetCount(source) {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            var delay = 0.1
            if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
               let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                    ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
                if delay < 0.02 { delay = 0.1 }
            }
            total += delay
            frames.append(UIImage(cgImage: cg))
        }
        let image = frames.count > 1 ? UIImage.animatedImage(with: frames, duration: total) : frames.first
        cache[name] = image
        return image
    }
}

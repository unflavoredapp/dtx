import Foundation
import UIKit
import SwiftUI

// MARK: - Raw requests (the build upload sends bytes, not JSON)

private struct ErrMsg: Decodable { var error: String? }

extension Api {
    /// Sends raw bytes (one piece of the libraries zip).
    func upload(_ method: String, _ path: String, body: Data) async throws -> Data {
        guard let u = URL(string: base + path), u.scheme == "https" else { throw ApiError.bad }
        var r = URLRequest(url: u, timeoutInterval: 180)
        r.httpMethod = method
        r.setValue("1", forHTTPHeaderField: "x-dt")
        r.setValue(base, forHTTPHeaderField: "Origin")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: r, from: body)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            let msg = (try? JSONDecoder().decode(ErrMsg.self, from: data))?.error
            throw ApiError.server(msg ?? "The server answered with error \(h.statusCode).", h.statusCode)
        }
        return data
    }
}

// MARK: - A zip with no compression (the server reads the libraries out of it)

enum ZipStore {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    static func build(_ files: [(name: String, data: Data)]) -> Data {
        var out = Data(), central = Data()
        for f in files {
            let name = Data(f.name.utf8), crc = crc32(f.data), size = UInt32(f.data.count), offset = UInt32(out.count)
            out.le32(0x04034b50); out.le16(20); out.le16(0x0800); out.le16(0); out.le16(0); out.le16(0x21)
            out.le32(crc); out.le32(size); out.le32(size); out.le16(name.count); out.le16(0)
            out.append(name); out.append(f.data)
            central.le32(0x02014b50); central.le16(20); central.le16(20); central.le16(0x0800); central.le16(0); central.le16(0); central.le16(0x21)
            central.le32(crc); central.le32(size); central.le32(size); central.le16(name.count); central.le16(0); central.le16(0)
            central.le16(0); central.le16(0); central.le32(0); central.le32(offset)
            central.append(name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.le32(0x06054b50); out.le16(0); out.le16(0); out.le16(files.count); out.le16(files.count)
        out.le32(UInt32(central.count)); out.le32(cdOffset); out.le16(0)
        return out
    }
}

private extension Data {
    mutating func le16(_ v: Int) { append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF)) }
    mutating func le32(_ v: UInt32) { for i in 0..<4 { append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
}

// MARK: - Downloading the finished IPA to the phone, with progress

final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private var cont: CheckedContinuation<URL, Error>?
    private var progress: ((Double) -> Void)?
    private var name = "app.ipa"
    private var session: URLSession?

    func download(path: String, name: String, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let u = URL(string: Api.shared.base + path), u.scheme == "https" else { throw ApiError.bad }
        var r = URLRequest(url: u, timeoutInterval: 600)
        r.setValue("1", forHTTPHeaderField: "x-dt")
        r.setValue(Api.shared.base, forHTTPHeaderField: "Origin")
        self.progress = progress
        self.name = name.replacingOccurrences(of: "/", with: "_")
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                self.cont = c
                s.downloadTask(with: r).resume()
            }
        } onCancel: { s.invalidateAndCancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let h = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            cont?.resume(throwing: ApiError.server("The server answered with error \(h.statusCode).", h.statusCode)); cont = nil; return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name.isEmpty ? "app.ipa" : name)
        do { try FileManager.default.moveItem(at: location, to: dest); cont?.resume(returning: dest) }
        catch { cont?.resume(throwing: error) }
        cont = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, let c = cont { c.resume(throwing: error); cont = nil }
        session.finishTasksAndInvalidate()
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

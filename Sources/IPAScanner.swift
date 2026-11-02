import Foundation

/// Lists the dylibs and frameworks inside an IPA without downloading the whole file: it reads the zip's index from the end
/// of the file with HTTP range requests (a few hundred KB even for a 500 MB IPA).
enum IPAScanner {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }

    static func scan(_ url: URL) async throws -> [SetItem] {
        guard url.scheme == "https" else { throw Failure("That link isn't https.") }
        // 1. the end of the file holds the zip's "end of central directory" record
        let (tail, total) = try await range(url, "bytes=-65536")
        guard let eocd = find(tail, sig: 0x06054b50, from: tail.count - 22) else { throw Failure("That doesn't look like an IPA (no zip index).") }
        var entries = Int(tail.u16(eocd + 10)), cdSize = Int(tail.u32(eocd + 12)), cdOffset = Int(tail.u32(eocd + 16))
        // zip64: the real numbers sit in another record just before
        if cdOffset == 0xFFFF_FFFF || entries == 0xFFFF || cdSize == 0xFFFF_FFFF {
            guard let loc = find(tail, sig: 0x07064b50, from: eocd - 20) else { throw Failure("This IPA uses a zip layout the app can't read.") }
            let z64 = Int(tail.u64(loc + 8))
            let (z, _) = try await range(url, "bytes=\(z64)-\(z64 + 55)")
            guard z.count >= 56, z.u32(0) == 0x06064b50 else { throw Failure("This IPA uses a zip layout the app can't read.") }
            entries = Int(z.u64(32)); cdSize = Int(z.u64(40)); cdOffset = Int(z.u64(48))
        }
        guard cdSize > 0, cdSize < 24_000_000, cdOffset >= 0, cdOffset + cdSize <= total else { throw Failure("The IPA's index looks damaged.") }
        // 2. the index itself: one record per file in the IPA
        let (cd, _) = try await range(url, "bytes=\(cdOffset)-\(cdOffset + cdSize - 1)")
        var libs: [String: SetItem] = [:]
        var p = 0, seen = 0
        while p + 46 <= cd.count, cd.u32(p) == 0x02014b50, seen < max(entries, 1) + 10 {
            seen += 1
            var size = Int64(cd.u32(p + 24))
            let nameLen = Int(cd.u16(p + 28)), extraLen = Int(cd.u16(p + 30)), commentLen = Int(cd.u16(p + 32))
            guard p + 46 + nameLen + extraLen <= cd.count else { break }
            let name = String(decoding: cd.subdata(in: (p + 46)..<(p + 46 + nameLen)), as: UTF8.self)
            if size == 0xFFFF_FFFF {   // zip64 extra field carries the real size
                var e = p + 46 + nameLen; let end = e + extraLen
                while e + 4 <= end { let id = cd.u16(e), len = Int(cd.u16(e + 2)); if id == 1, e + 12 <= end { size = Int64(cd.u64(e + 4)) }; e += 4 + len }
            }
            p += 46 + nameLen + extraLen + commentLen
            guard !name.hasSuffix("/") else { continue }
            consider(name, size, into: &libs)
        }
        return libs.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Payload/App.app/Frameworks/X.framework/... -> one framework "X.framework" (sizes added up);
    /// Payload/App.app/**/Y.dylib -> a dylib. Extensions and watch apps are skipped.
    private static func consider(_ path: String, _ size: Int64, into libs: inout [String: SetItem]) {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "Payload", parts[1].hasSuffix(".app") else { return }
        let inner = Array(parts.dropFirst(2))
        if inner.contains(where: { $0.hasSuffix(".appex") || $0.hasSuffix(".app") }) { return }
        if let fw = inner.first(where: { $0.hasSuffix(".framework") }) {
            let old = libs["f:" + fw]
            libs["f:" + fw] = SetItem(name: fw, type: "framework", size: (old?.size ?? 0) + size)
        } else if let last = inner.last, last.hasSuffix(".dylib") {
            libs["d:" + last] = SetItem(name: last, type: "dylib", size: size)
        }
    }

    // MARK: network and bytes

    private static func range(_ url: URL, _ spec: String) async throws -> (Data, Int) {
        var r = URLRequest(url: url, timeoutInterval: 25)
        r.setValue(spec, forHTTPHeaderField: "Range")
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw Failure("No answer from the repo's server.") }
        guard h.statusCode == 206 else {
            if h.statusCode == 200 { throw Failure("That server doesn't allow reading part of a file, so the IPA can't be scanned without downloading it.") }
            throw Failure("The repo's server answered with error \(h.statusCode).")
        }
        var total = data.count
        if let cr = h.value(forHTTPHeaderField: "Content-Range"), let slash = cr.lastIndex(of: "/"), let n = Int(cr[cr.index(after: slash)...]) { total = n }
        return (data, total)
    }

    private static func find(_ d: Data, sig: UInt32, from: Int) -> Int? {
        var i = min(from, d.count - 4)
        while i >= 0 { if d.u32(i) == sig { return i }; i -= 1 }
        return nil
    }
}

private extension Data {
    func u16(_ o: Int) -> UInt16 { guard o >= 0, o + 2 <= count else { return 0 }; return UInt16(self[startIndex + o]) | UInt16(self[startIndex + o + 1]) << 8 }
    func u32(_ o: Int) -> UInt32 { guard o >= 0, o + 4 <= count else { return 0 }; return UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
    func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 }
}

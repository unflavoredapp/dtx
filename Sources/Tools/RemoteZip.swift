import Foundation
import Compression

struct ZipError: LocalizedError {
    let errorDescription: String?
    init(_ m: String) { errorDescription = m }
}

struct ZipEntry {
    let name: String
    let compressed: Int64
    let size: Int64
    let method: UInt16
    let offset: Int64
    var isFolder: Bool { name.hasSuffix("/") }
}

/// Reads a zip (an IPA) that lives on a web server without downloading all of it: the index comes from the end of the file,
/// and single files are fetched with HTTP range requests. A 500 MB IPA costs a few hundred KB to list and open its Info.plist.
struct RemoteZip {
    let url: URL
    let total: Int
    let entries: [ZipEntry]

    static func open(_ url: URL) async throws -> RemoteZip {
        guard url.scheme == "https" else { throw ZipError("That link isn't https.") }
        // 1. the end of the file holds the "end of central directory" record
        let (tail, total) = try await range(url, "bytes=-65536")
        guard let eocd = find(tail, sig: 0x06054b50, from: tail.count - 22) else { throw ZipError("That doesn't look like an IPA (no zip index).") }
        var count = Int(tail.zu16(eocd + 10)), cdSize = Int(tail.zu32(eocd + 12)), cdOffset = Int(tail.zu32(eocd + 16))
        if cdOffset == 0xFFFF_FFFF || count == 0xFFFF || cdSize == 0xFFFF_FFFF {      // zip64: the real numbers are in another record
            guard let loc = find(tail, sig: 0x07064b50, from: eocd - 20) else { throw ZipError("This IPA uses a zip layout the app can't read.") }
            let z64 = Int(tail.zu64(loc + 8))
            let (z, _) = try await range(url, "bytes=\(z64)-\(z64 + 55)")
            guard z.count >= 56, z.zu32(0) == 0x06064b50 else { throw ZipError("This IPA uses a zip layout the app can't read.") }
            count = Int(z.zu64(32)); cdSize = Int(z.zu64(40)); cdOffset = Int(z.zu64(48))
        }
        guard cdSize > 0, cdSize < 24_000_000, cdOffset >= 0, cdOffset + cdSize <= total else { throw ZipError("The IPA's index looks damaged.") }
        // 2. the index: one record per file
        let (cd, _) = try await range(url, "bytes=\(cdOffset)-\(cdOffset + cdSize - 1)")
        var out: [ZipEntry] = []
        var p = 0
        while p + 46 <= cd.count, cd.zu32(p) == 0x02014b50, out.count < max(count, 1) + 10 {
            let method = cd.zu16(p + 10)
            var comp = Int64(cd.zu32(p + 20)), size = Int64(cd.zu32(p + 24)), off = Int64(cd.zu32(p + 42))
            let nameLen = Int(cd.zu16(p + 28)), extraLen = Int(cd.zu16(p + 30)), commentLen = Int(cd.zu16(p + 32))
            guard p + 46 + nameLen + extraLen <= cd.count else { break }
            let name = String(decoding: cd.subdata(in: (p + 46)..<(p + 46 + nameLen)), as: UTF8.self)
            if size == 0xFFFF_FFFF || comp == 0xFFFF_FFFF || off == 0xFFFF_FFFF {      // zip64 extra field, fields in this fixed order
                var e = p + 46 + nameLen; let end = e + extraLen
                while e + 4 <= end {
                    let id = cd.zu16(e), len = Int(cd.zu16(e + 2))
                    if id == 1 {
                        var q = e + 4
                        if size == 0xFFFF_FFFF { size = Int64(cd.zu64(q)); q += 8 }
                        if comp == 0xFFFF_FFFF { comp = Int64(cd.zu64(q)); q += 8 }
                        if off == 0xFFFF_FFFF { off = Int64(cd.zu64(q)) }
                    }
                    e += 4 + len
                }
            }
            p += 46 + nameLen + extraLen + commentLen
            out.append(ZipEntry(name: name, compressed: comp, size: size, method: method, offset: off))
        }
        return RemoteZip(url: url, total: total, entries: out)
    }

    /// One file from inside the zip, unpacked. `limit` stops a huge file from being pulled by accident.
    func read(_ e: ZipEntry, limit: Int = 4_000_000) async throws -> Data {
        guard e.size <= Int64(limit), e.compressed <= Int64(limit) else { throw ZipError("\(e.name) is too big to open here.") }
        let want = Int(e.compressed) + 30 + e.name.utf8.count + 1024
        let end = min(total, Int(e.offset) + want) - 1
        let (d, _) = try await Self.range(url, "bytes=\(e.offset)-\(end)")
        guard d.zu32(0) == 0x04034b50 else { throw ZipError("The IPA's index points at the wrong place for \(e.name).") }
        let start = 30 + Int(d.zu16(26)) + Int(d.zu16(28))
        var packed: Data
        if d.count >= start + Int(e.compressed) { packed = d.subdata(in: start..<(start + Int(e.compressed))) }
        else { packed = try await Self.range(url, "bytes=\(Int(e.offset) + start)-\(Int(e.offset) + start + Int(e.compressed) - 1)").0 }
        switch e.method {
        case 0: return packed
        case 8: return try Self.inflate(packed, expected: Int(e.size))
        default: throw ZipError("\(e.name) uses a compression the app can't open.")
        }
    }

    /// The first `maxOut` bytes of a (possibly huge) file, unpacked from just the start of its compressed data.
    /// Enough to read a program's headers without pulling the whole executable.
    func readPrefix(_ e: ZipEntry, maxOut: Int = 1_000_000) async throws -> Data {
        let take = Int(min(e.compressed, Int64(max(maxOut / 2, 400_000))))
        let end = min(total, Int(e.offset) + 30 + e.name.utf8.count + 1024 + take) - 1
        let (d, _) = try await Self.range(url, "bytes=\(e.offset)-\(end)")
        guard d.zu32(0) == 0x04034b50 else { throw ZipError("The IPA's index points at the wrong place for \(e.name).") }
        let start = 30 + Int(d.zu16(26)) + Int(d.zu16(28))
        guard d.count > start else { throw ZipError("Couldn't read \(e.name).") }
        let packed = d.subdata(in: start..<min(d.count, start + take))
        switch e.method {
        case 0: return packed.prefix(maxOut)
        case 8: return Self.inflatePrefix(packed, maxOut: maxOut)
        default: throw ZipError("\(e.name) uses a compression the app can't open.")
        }
    }

    // MARK: pieces

    /// Streaming unpack: gives back whatever the start of a deflate stream decodes to, even when the stream is cut off.
    static func inflatePrefix(_ src: Data, maxOut: Int) -> Data {
        let size = 64 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        let sp = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { buf.deallocate(); sp.deallocate() }
        guard compression_stream_init(sp, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else { return Data() }
        defer { compression_stream_destroy(sp) }
        var out = Data()
        src.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            sp.pointee.src_ptr = base; sp.pointee.src_size = src.count
            sp.pointee.dst_ptr = buf; sp.pointee.dst_size = size
            while out.count < maxOut {
                let status = compression_stream_process(sp, 0)
                let made = size - sp.pointee.dst_size
                if made > 0 { out.append(buf, count: made) }
                sp.pointee.dst_ptr = buf; sp.pointee.dst_size = size
                if status != COMPRESSION_STATUS_OK { break }          // finished, or the cut-off end of the data
                if made == 0 && sp.pointee.src_size == 0 { break }
            }
        }
        return out.count > maxOut ? out.prefix(maxOut) : out
    }

    static func inflate(_ src: Data, expected: Int) throws -> Data {
        guard expected > 0 else { return Data() }
        var dst = Data(count: expected)
        let n = dst.withUnsafeMutableBytes { d -> Int in
            src.withUnsafeBytes { s -> Int in
                guard let db = d.bindMemory(to: UInt8.self).baseAddress, let sb = s.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(db, expected, sb, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n == expected else { throw ZipError("Couldn't unpack that file.") }
        return dst
    }

    static func range(_ url: URL, _ spec: String) async throws -> (Data, Int) {
        var r = URLRequest(url: url, timeoutInterval: 25)
        r.setValue(spec, forHTTPHeaderField: "Range")
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw ZipError("No answer from the server.") }
        guard h.statusCode == 206 else {
            if h.statusCode == 200 { throw ZipError("That server doesn't allow reading part of a file, so the IPA can't be opened without downloading it.") }
            throw ZipError("The server answered with error \(h.statusCode).")
        }
        var total = data.count
        if let cr = h.value(forHTTPHeaderField: "Content-Range"), let slash = cr.lastIndex(of: "/"), let n = Int(cr[cr.index(after: slash)...]) { total = n }
        return (data, total)
    }

    private static func find(_ d: Data, sig: UInt32, from: Int) -> Int? {
        var i = min(from, d.count - 4)
        while i >= 0 { if d.zu32(i) == sig { return i }; i -= 1 }
        return nil
    }
}

extension Data {
    func zu16(_ o: Int) -> UInt16 { guard o >= 0, o + 2 <= count else { return 0 }; return UInt16(self[startIndex + o]) | UInt16(self[startIndex + o + 1]) << 8 }
    func zu32(_ o: Int) -> UInt32 { UInt32(zu16(o)) | UInt32(zu16(o + 2)) << 16 }
    func zu64(_ o: Int) -> UInt64 { UInt64(zu32(o)) | UInt64(zu32(o + 4)) << 32 }
}

// MARK: - the dylib / framework listing used by the app page

enum IPAScanner {
    static func scan(_ url: URL) async throws -> [SetItem] {
        let zip = try await RemoteZip.open(url)
        var libs: [String: SetItem] = [:]
        for e in zip.entries where !e.isFolder { consider(e.name, e.size, into: &libs) }
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
}

import Foundation

/// Reads a zip (an IPA, or any other zip/dylib attached straight into a chat) that lives on disk.
/// Same record layout and parsing as RemoteZip, but every byte comes from the local file instead of an HTTP range request,
/// so a file attached in the Ai-Decrypt chat can be scanned with no server round trip at all.
struct LocalZip {
    let total: Int
    let entries: [ZipEntry]
    private let fileURL: URL

    static func open(_ fileURL: URL) throws -> LocalZip {
        guard let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > 0 else {
            throw ZipError("That file is empty or couldn't be read.")
        }
        let total = size
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let tailStart = max(0, total - 65536)
        try handle.seek(toOffset: UInt64(tailStart))
        let tail = handle.readData(ofLength: total - tailStart)
        guard let eocd = find(tail, sig: 0x06054b50, from: tail.count - 22) else {
            throw ZipError("That doesn't look like a zip or IPA (no zip index).")
        }
        var count = Int(tail.zu16(eocd + 10)), cdSize = Int(tail.zu32(eocd + 12)), cdOffset = Int(tail.zu32(eocd + 16))
        if cdOffset == 0xFFFF_FFFF || count == 0xFFFF || cdSize == 0xFFFF_FFFF {
            guard let loc = find(tail, sig: 0x07064b50, from: eocd - 20) else { throw ZipError("This file uses a zip layout the app can't read.") }
            let z64 = Int(tail.zu64(loc + 8))
            try handle.seek(toOffset: UInt64(z64))
            let z = handle.readData(ofLength: 56)
            guard z.count >= 56, z.zu32(0) == 0x06064b50 else { throw ZipError("This file uses a zip layout the app can't read.") }
            count = Int(z.zu64(32)); cdSize = Int(z.zu64(40)); cdOffset = Int(z.zu64(48))
        }
        guard cdSize > 0, cdSize < 24_000_000, cdOffset >= 0, cdOffset + cdSize <= total else { throw ZipError("The zip's index looks damaged.") }
        try handle.seek(toOffset: UInt64(cdOffset))
        let cd = handle.readData(ofLength: cdSize)

        var out: [ZipEntry] = []
        var p = 0
        while p + 46 <= cd.count, cd.zu32(p) == 0x02014b50, out.count < max(count, 1) + 10 {
            let method = cd.zu16(p + 10)
            var comp = Int64(cd.zu32(p + 20)), size = Int64(cd.zu32(p + 24)), off = Int64(cd.zu32(p + 42))
            let nameLen = Int(cd.zu16(p + 28)), extraLen = Int(cd.zu16(p + 30)), commentLen = Int(cd.zu16(p + 32))
            guard p + 46 + nameLen + extraLen <= cd.count else { break }
            let name = String(decoding: cd.subdata(in: (p + 46)..<(p + 46 + nameLen)), as: UTF8.self)
            if size == 0xFFFF_FFFF || comp == 0xFFFF_FFFF || off == 0xFFFF_FFFF {
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
        return LocalZip(total: total, entries: out, fileURL: fileURL)
    }

    func read(_ e: ZipEntry, limit: Int = 4_000_000) throws -> Data {
        guard e.size <= Int64(limit), e.compressed <= Int64(limit) else { throw ZipError("\(e.name) is too big to open here.") }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(e.offset))
        let want = Int(e.compressed) + 30 + e.name.utf8.count + 1024
        let d = handle.readData(ofLength: max(0, min(total - Int(e.offset), want)))
        guard d.zu32(0) == 0x04034b50 else { throw ZipError("The zip's index points at the wrong place for \(e.name).") }
        let start = 30 + Int(d.zu16(26)) + Int(d.zu16(28))
        guard d.count >= start + Int(e.compressed) else { throw ZipError("Couldn't read \(e.name).") }
        let packed = d.subdata(in: start..<(start + Int(e.compressed)))
        switch e.method {
        case 0: return packed
        case 8: return try RemoteZip.inflate(packed, expected: Int(e.size))
        default: throw ZipError("\(e.name) uses a compression the app can't open.")
        }
    }

    func readPrefix(_ e: ZipEntry, maxOut: Int = 1_000_000) throws -> Data {
        let take = Int(min(e.compressed, Int64(max(maxOut / 2, 400_000))))
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(e.offset))
        let want = 30 + e.name.utf8.count + 1024 + take
        let d = handle.readData(ofLength: max(0, min(total - Int(e.offset), want)))
        guard d.zu32(0) == 0x04034b50 else { throw ZipError("The zip's index points at the wrong place for \(e.name).") }
        let start = 30 + Int(d.zu16(26)) + Int(d.zu16(28))
        guard d.count > start else { throw ZipError("Couldn't read \(e.name).") }
        let packed = d.subdata(in: start..<min(d.count, start + take))
        switch e.method {
        case 0: return packed.prefix(maxOut)
        case 8: return RemoteZip.inflatePrefix(packed, maxOut: maxOut)
        default: throw ZipError("\(e.name) uses a compression the app can't open.")
        }
    }

    private static func find(_ d: Data, sig: UInt32, from: Int) -> Int? {
        var i = min(from, d.count - 4)
        while i >= 0 { if d.zu32(i) == sig { return i }; i -= 1 }
        return nil
    }
}

/// Wraps either a remote (https range-request) zip or a local on-disk zip behind one interface,
/// so a bundled Tool's `run` closure doesn't need to care which one it got.
enum AnyZip {
    case remote(RemoteZip)
    case local(LocalZip)

    var total: Int { switch self { case .remote(let z): return z.total; case .local(let z): return z.total } }
    var entries: [ZipEntry] { switch self { case .remote(let z): return z.entries; case .local(let z): return z.entries } }

    func read(_ e: ZipEntry, limit: Int = 4_000_000) async throws -> Data {
        switch self {
        case .remote(let z): return try await z.read(e, limit: limit)
        case .local(let z): return try z.read(e, limit: limit)
        }
    }

    func readPrefix(_ e: ZipEntry, maxOut: Int = 1_000_000) async throws -> Data {
        switch self {
        case .remote(let z): return try await z.readPrefix(e, maxOut: maxOut)
        case .local(let z): return try z.readPrefix(e, maxOut: maxOut)
        }
    }
}

enum ZipSource {
    /// Opens whatever the tool's context points at: a file attached locally in chat if there is one, otherwise the remote IPA link.
    static func open(_ ctx: ToolContext) async throws -> AnyZip {
        if let local = ctx.localFile { return .local(try LocalZip.open(local)) }
        return .remote(try await RemoteZip.open(ctx.url))
    }
}

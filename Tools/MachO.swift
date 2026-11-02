import Foundation

/// Reads the headers of a Mach-O program (what `otool -l` shows): CPU, encryption, linked libraries, run paths.
struct MachOSlice {
    var cpu = ""
    var encrypted: Bool?                // nil: no encryption command at all
    var libs: [String] = []
    var rpaths: [String] = []
    var uuid = ""
    var minOS = ""
    var sdk = ""
    var signed = false
    var parsed = true                   // false: only the CPU is known (the slice starts beyond what was read)
}

enum MachO {
    static func parse(_ d: Data) -> [MachOSlice] {
        guard d.count >= 8 else { return [] }
        let magicBE = d.be32(0)
        if magicBE == 0xCAFEBABE || magicBE == 0xCAFEBABF {            // a fat file: several programs in one
            let n = Int(d.be32(4)), wide = magicBE == 0xCAFEBABF, step = wide ? 32 : 20
            var out: [MachOSlice] = []
            for i in 0..<min(n, 8) {
                let o = 8 + i * step
                guard o + step <= d.count else { break }
                let cpu = d.be32(o), sub = d.be32(o + 4)
                let off = wide ? Int(d.be64(o + 8)) : Int(d.be32(o + 8))
                if off + 32 <= d.count, var s = thin(d, at: off) { s.cpu = cpuName(cpu, sub); out.append(s) }
                else { var s = MachOSlice(); s.cpu = cpuName(cpu, sub); s.parsed = false; out.append(s) }
            }
            return out
        }
        return thin(d, at: 0).map { [$0] } ?? []
    }

    private static func thin(_ d: Data, at base: Int) -> MachOSlice? {
        guard base + 32 <= d.count, d.le32(base) == 0xFEEDFACF else { return nil }      // 64-bit little-endian programs (every modern iOS app)
        var s = MachOSlice()
        s.cpu = cpuName(d.le32(base + 4), d.le32(base + 8))
        let ncmds = Int(d.le32(base + 16))
        var p = base + 32
        func str(_ at: Int, _ off: Int, _ size: Int) -> String {
            let a = at + off, b = at + size
            guard a >= 0, a < b, b <= d.count else { return "" }
            let bytes = d.subdata(in: a..<b)
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        for _ in 0..<ncmds {
            guard p + 8 <= d.count else { break }
            let cmd = d.le32(p), size = Int(d.le32(p + 4))
            guard size >= 8, p + size <= d.count else { break }
            switch cmd {
            case 0x2C, 0x21: s.encrypted = d.le32(p + 16) != 0                           // LC_ENCRYPTION_INFO(_64): cryptid
            case 0xC, 0x8000_0018, 0x8000_001F, 0x8000_0023:                              // load / weak / re-export / upward dylib
                let name = str(p, Int(d.le32(p + 8)), size); if !name.isEmpty { s.libs.append(name) }
            case 0x8000_001C:                                                             // LC_RPATH
                let path = str(p, Int(d.le32(p + 8)), size); if !path.isEmpty { s.rpaths.append(path) }
            case 0x1B:                                                                    // LC_UUID
                s.uuid = (0..<16).map { String(format: "%02X", d[d.startIndex + p + 8 + $0]) }.joined()
            case 0x32:                                                                    // LC_BUILD_VERSION
                s.minOS = version(d.le32(p + 12)); s.sdk = version(d.le32(p + 16))
            case 0x25:                                                                    // LC_VERSION_MIN_IPHONEOS
                s.minOS = version(d.le32(p + 8)); s.sdk = version(d.le32(p + 12))
            case 0x1D: s.signed = true                                                    // LC_CODE_SIGNATURE
            default: break
            }
            p += size
        }
        return s
    }

    private static func version(_ v: UInt32) -> String {
        let major = v >> 16, minor = (v >> 8) & 0xFF, patch = v & 0xFF
        return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    private static func cpuName(_ cpu: UInt32, _ sub: UInt32) -> String {
        switch cpu {
        case 0x0100_000C: return (sub & 0xFF) == 2 ? "arm64e" : "arm64"
        case 0x0000_000C: return "armv7"
        case 0x0100_0007: return "x86_64"
        case 0x0000_0007: return "i386"
        default: return String(format: "cpu 0x%X", cpu)
        }
    }
}

private extension Data {
    func le32(_ o: Int) -> UInt32 { zu32(o) }
    func be32(_ o: Int) -> UInt32 { guard o + 4 <= count else { return 0 }; return (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(self[startIndex + o + $1]) } }
    func be64(_ o: Int) -> UInt64 { UInt64(be32(o)) << 32 | UInt64(be32(o + 4)) }
}

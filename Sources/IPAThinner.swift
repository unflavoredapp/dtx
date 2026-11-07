import Foundation
import ZIPFoundation

/// Drops every non-arm64 slice from the fat binaries inside an IPA (about 30% smaller, A8 and newer devices).
nonisolated enum IPAThinner {
    struct Result { let url: URL; let savedBytes: Int64 }

    static func thin(_ ipa: URL) throws -> Result {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("thin-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try fm.unzipItem(at: ipa, to: work)

        var saved: Int64 = 0
        if let walk = fm.enumerator(at: work, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in walk {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
                let head = handle.readData(ofLength: 4)
                try? handle.close()
                guard head == Data([0xCA, 0xFE, 0xBA, 0xBE]) else { continue }
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                guard let range = MachOThin.arm64Slice(of: data) else { continue }
                let slim = Data(data[range])
                try slim.write(to: file, options: .atomic)
                saved += Int64(data.count - slim.count)
            }
        }

        let out = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
        try fm.zipItem(at: work.appendingPathComponent("Payload", isDirectory: true), to: out, shouldKeepParent: true, compressionMethod: .deflate)
        return Result(url: out, savedBytes: saved)
    }
}

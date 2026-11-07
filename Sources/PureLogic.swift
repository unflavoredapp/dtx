import Foundation

// Foundation-only logic: no UIKit, ZIPFoundation or signing engine, so it is also checked on its own in CI (Tests/LogicTests).

// MARK: - A small parallel DAG runner

/// One step of work and the steps that must finish first.
nonisolated struct DAGNode: Sendable {
    let id: String
    let deps: [String]
    let work: @Sendable () async throws -> Void
}

nonisolated enum DAGState: Sendable, Equatable {
    case running, done, failed(String), skipped
}

nonisolated enum DAGRunner {
    /// Runs every node as soon as all of its dependencies are done, up to `maxConcurrent` at a time.
    /// A failed node skips everything that depends on it; unrelated branches keep going.
    @discardableResult
    static func run(_ nodes: [DAGNode], maxConcurrent: Int,
                    progress: @escaping @Sendable (String, DAGState) -> Void) async -> [String: DAGState] {
        var byID: [String: DAGNode] = [:]
        var waiting: [String: Set<String>] = [:]
        var dependents: [String: [String]] = [:]
        for n in nodes {
            byID[n.id] = n
            waiting[n.id] = Set(n.deps)
            for d in n.deps { dependents[d, default: []].append(n.id) }
        }
        var results: [String: DAGState] = [:]
        var ready: [String] = nodes.filter { $0.deps.isEmpty }.map(\.id)
        var running = 0
        let limit = max(1, maxConcurrent)

        await withTaskGroup(of: (String, String?).self) { group in
            while true {
                while running < limit, !ready.isEmpty {
                    let id = ready.removeFirst()
                    guard let node = byID[id], results[id] == nil else { continue }
                    running += 1
                    progress(id, .running)
                    group.addTask {
                        do { try await node.work(); return (id, nil) }
                        catch { return (id, error.localizedDescription) }
                    }
                }
                guard running > 0, let finished = await group.next() else { break }
                running -= 1
                let id = finished.0
                if let message = finished.1 {
                    results[id] = .failed(message)
                    progress(id, .failed(message))
                    // skip everything downstream
                    var stack = dependents[id] ?? []
                    while let next = stack.popLast() {
                        if results[next] == nil {
                            results[next] = .skipped
                            progress(next, .skipped)
                            stack.append(contentsOf: dependents[next] ?? [])
                        }
                    }
                } else {
                    results[id] = .done
                    progress(id, .done)
                    for d in dependents[id] ?? [] {
                        waiting[d]?.remove(id)
                        if waiting[d]?.isEmpty == true, results[d] == nil { ready.append(d) }
                    }
                }
            }
        }
        return results
    }
}

// MARK: - Dylib file names

/// Names to use inside the app for a list of dylibs: the file name, or `name-<index>.ext` when it was already taken.
nonisolated func uniqueDylibNames(_ urls: [URL]) -> [String] {
    var used = Set<String>()
    return urls.enumerated().map { i, u in
        var n = u.lastPathComponent
        if !used.insert(n.lowercased()).inserted {
            let ext = u.pathExtension
            n = u.deletingPathExtension().lastPathComponent + "-\(i)" + (ext.isEmpty ? "" : "." + ext)
            used.insert(n.lowercased())
        }
        return n
    }
}

// MARK: - Fat binaries

nonisolated enum MachOThin {
    /// The byte range of the arm64 slice inside a fat (universal) file, or nil if the file isn't fat, has no arm64 slice,
    /// or only looks fat (a Java class file shares the same first four bytes).
    static func arm64Slice(of data: Data) -> Range<Int>? {
        let base = data.startIndex
        func be32(_ o: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(data[base + o + $1]) }
        }
        guard data.count >= 8, be32(0) == 0xCAFEBABE else { return nil }
        let n = Int(be32(4))
        guard n > 0, n <= 16, data.count >= 8 + n * 20 else { return nil }
        for i in 0..<n {
            let b = 8 + i * 20
            let cpu = be32(b), off = Int(be32(b + 8)), size = Int(be32(b + 12))
            guard cpu == 0x0100000C, size > 4, off >= 8 + n * 20, off + size <= data.count else { continue }
            // a real slice starts with the 64-bit Mach-O magic (little endian: CF FA ED FE)
            guard data[base + off] == 0xCF, data[base + off + 1] == 0xFA, data[base + off + 2] == 0xED, data[base + off + 3] == 0xFE else { continue }
            return off..<(off + size)
        }
        return nil
    }
}

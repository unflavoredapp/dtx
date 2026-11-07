import Foundation
import ZIPFoundation

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

// MARK: - Inject + repackage (no signing)

/// One app moving through the pipeline. Each step touches its own fields and the graph orders the steps,
/// so no two steps ever write the same thing at once.
nonisolated final class BatchJob: @unchecked Sendable {
    enum Source: Sendable { case remote(URL), local(URL) }
    let id: String
    let name: String
    let source: Source
    let work: URL
    var ipa: URL { work.appendingPathComponent("in.ipa") }
    var extracted: URL { work.appendingPathComponent("x", isDirectory: true) }
    var output: URL { work.appendingPathComponent("out.ipa") }
    var appURL: URL?
    var exeURL: URL?
    var meta: IPAMeta?

    init(id: String, name: String, source: Source) {
        self.id = id; self.name = name; self.source = source
        self.work = FileManager.default.temporaryDirectory.appendingPathComponent("batch-" + UUID().uuidString, isDirectory: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: work) }
}

nonisolated enum BatchInjector {
    static let unsignedTag = "Unsigned · injected"

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// fetch ─┬─ meta ──────────────────────────────┐
    ///        └─ unpack ─┬─ copy 1 ─┐                ├─ pack ─ save
    ///                   ├─ copy 2 ─┤                │
    ///                   └─ elleKit ─ inject 1 ─ inject 2 ─┘
    /// Copies run side by side; injections edit one binary so they run in a chain.
    static func graph(for job: BatchJob, dylibs: [(url: URL, weak: Bool)],
                      save: @escaping @Sendable (BatchJob) async throws -> Void) -> [DAGNode] {
        let p = job.id + "/"
        var nodes: [DAGNode] = []

        nodes.append(DAGNode(id: p + "fetch", deps: []) {
            try FileManager.default.createDirectory(at: job.work, withIntermediateDirectories: true)
            switch job.source {
            case .local(let url):
                try FileManager.default.copyItem(at: url, to: job.ipa)
            case .remote(let url):
                let (tmp, response) = try await URLSession.shared.download(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw Failure(message: "Download failed (HTTP \(http.statusCode)).")
                }
                try FileManager.default.moveItem(at: tmp, to: job.ipa)
            }
        })

        nodes.append(DAGNode(id: p + "meta", deps: [p + "fetch"]) {
            job.meta = try? IPAMeta.read(job.ipa)
        })

        nodes.append(DAGNode(id: p + "unpack", deps: [p + "fetch"]) {
            let fm = FileManager.default
            try fm.createDirectory(at: job.extracted, withIntermediateDirectories: true)
            try fm.unzipItem(at: job.ipa, to: job.extracted)
            let payload = job.extracted.appendingPathComponent("Payload", isDirectory: true)
            guard let app = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
                throw Failure(message: "No app found inside the IPA.")
            }
            job.appURL = app
            let plist = try Data(contentsOf: app.appendingPathComponent("Info.plist"))
            let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
            let exe = (info?["CFBundleExecutable"] as? String) ?? app.deletingPathExtension().lastPathComponent
            job.exeURL = app.appendingPathComponent(exe)
            try? fm.removeItem(at: job.ipa)      // the unpacked tree is all we need now
        })

        var copyIDs: [String] = []
        for (i, d) in dylibs.enumerated() {
            let id = p + "copy\(i)"
            copyIDs.append(id)
            nodes.append(DAGNode(id: id, deps: [p + "unpack"]) {
                guard let app = job.appURL else { throw Failure(message: "App folder missing.") }
                let dest = app.appendingPathComponent(d.url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: d.url, to: dest)
            })
        }

        // tweaks built against CydiaSubstrate need ElleKit's shim next to them
        let substrateID = p + "substrate"
        nodes.append(DAGNode(id: substrateID, deps: [p + "unpack"]) {
            guard let app = job.appURL, let exe = job.exeURL else { throw Failure(message: "App folder missing.") }
            Signer.installSubstrate(into: app, mainExe: exe, onLog: nil)
        })

        var previous = substrateID
        var injectIDs: [String] = []
        for (i, d) in dylibs.enumerated() {
            let id = p + "inject\(i)"
            injectIDs.append(id)
            nodes.append(DAGNode(id: id, deps: [previous, p + "copy\(i)"]) {
                guard let exe = job.exeURL else { throw Failure(message: "Executable missing.") }
                try ZsignSigner.injectDylib(intoMachO: exe.path,
                                            dylibPath: "@executable_path/" + d.url.lastPathComponent,
                                            weak: d.weak, createIfMissing: true)
            })
            previous = id
        }

        nodes.append(DAGNode(id: p + "pack", deps: [previous, p + "meta"] + copyIDs) {
            let fm = FileManager.default
            let payload = job.extracted.appendingPathComponent("Payload", isDirectory: true)
            try? fm.removeItem(at: job.output)
            try fm.zipItem(at: payload, to: job.output, shouldKeepParent: true, compressionMethod: .none)
        })

        nodes.append(DAGNode(id: p + "save", deps: [p + "pack"]) { try await save(job) })
        return nodes
    }

    /// Display name for the step an id belongs to.
    static func stageLabel(_ nodeID: String) -> String {
        let step = nodeID.split(separator: "/").last.map(String.init) ?? nodeID
        if step.hasPrefix("copy") { return "Adding dylibs" }
        if step.hasPrefix("inject") { return "Injecting" }
        switch step {
        case "fetch": return "Getting the IPA"
        case "meta": return "Reading info"
        case "unpack": return "Unpacking"
        case "substrate": return "Preparing"
        case "pack": return "Repackaging"
        case "save": return "Saving"
        default: return step
        }
    }
}

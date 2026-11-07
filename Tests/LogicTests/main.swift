import Foundation

// Runs on the CI Mac with plain swiftc: swiftc Sources/PureLogic.swift Tests/LogicTests/main.swift
// No simulator, no XCTest, no app dependencies.

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if ok { print("ok   " + what) } else { print("FAIL " + what); failures += 1 }
}

func node(_ id: String, _ deps: [String] = [], log: Log, fail: Bool = false) -> DAGNode {
    DAGNode(id: id, deps: deps) {
        await log.add(id)
        if fail { throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"]) }
    }
}

actor Log { var items: [String] = []; func add(_ s: String) { items.append(s) } }

func testDAG() async {
    let log = Log()
    let nodes = [node("a", log: log), node("b", ["a"], log: log), node("c", ["a"], log: log), node("d", ["b", "c"], log: log)]
    let r = await DAGRunner.run(nodes, maxConcurrent: 4) { _, _ in }
    let order = await log.items
    check(r.values.allSatisfy { $0 == .done }, "DAG: every node finishes")
    check(order.first == "a" && order.last == "d", "DAG: dependencies run first")
}

func testDAGFailure() async {
    let log = Log()
    let nodes = [node("a", log: log, fail: true), node("b", ["a"], log: log), node("c", log: log)]
    let r = await DAGRunner.run(nodes, maxConcurrent: 2) { _, _ in }
    check(r["b"] == .skipped, "DAG: a failed node skips what depends on it")
    check(r["c"] == .done, "DAG: unrelated branches keep going")
    if case .failed = r["a"] ?? .done { check(true, "DAG: the failure is reported") } else { check(false, "DAG: the failure is reported") }
}

func testNames() {
    let urls = ["/x/A.dylib", "/y/a.dylib", "/z/B.dylib"].map { URL(fileURLWithPath: $0) }
    let n = uniqueDylibNames(urls)
    check(Set(n.map { $0.lowercased() }).count == 3, "Names: a repeated file name gets its own name")
    check(n[0] == "A.dylib" && n[2] == "B.dylib", "Names: the first one keeps its name")
}

func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }

func testThin() {
    // header (8) + 2 arch entries (40) = 48; arm64 slice at 64, 16 bytes
    var d = Data(be32(0xCAFEBABE) + be32(2))
    d += Data(be32(7) + be32(3) + be32(48) + be32(8) + be32(4))              // x86 slice
    d += Data(be32(0x0100000C) + be32(0) + be32(64) + be32(16) + be32(4))    // arm64 slice
    d += Data(repeating: 0, count: 64 - d.count)
    d += Data([0xCF, 0xFA, 0xED, 0xFE] + [UInt8](repeating: 9, count: 12))
    let range = MachOThin.arm64Slice(of: d)
    check(range == 64..<80, "Thin: finds the arm64 slice")
    check(MachOThin.arm64Slice(of: Data(be32(0xCAFEBABE) + be32(52) + [UInt8](repeating: 0, count: 64))) == nil, "Thin: a Java class file is not treated as fat")
    check(MachOThin.arm64Slice(of: Data([1, 2, 3, 4, 5, 6, 7, 8])) == nil, "Thin: a plain file is left alone")
}

await testDAG()
await testDAGFailure()
testNames()
testThin()
print(failures == 0 ? "All logic tests passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)

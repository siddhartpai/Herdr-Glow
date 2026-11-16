import Testing
import Foundation
@testable import HerdrGlowCore

private let blockedTerminal = #"{"address":"t5","title":"Fix bug","cwd":"/tmp/a","status":{"app":"claude-code","state":"blocked"},"turn":3}"#

@Test func listAgentsKeepsOnlyReportingTerminals() async throws {
    let server = try FakeHerdrServer { _ in [
        #"{"jsonrpc":"2.0","id":"1","result":{"terminals":["# + blockedTerminal + #",{"address":"t6","status":null}]}}"#,
    ] }
    defer { server.stop() }
    let agents = try await HerdrClient(socketPath: server.path).listAgents()
    #expect(agents.map(\.paneID) == ["t5"])
    #expect(agents.first?.status == .blocked)
    #expect(agents.first?.completion == 3)
    #expect(server.requests.first?["method"] as? String == "terminal.list")
    #expect(server.requests.first?["jsonrpc"] as? String == "2.0")
}

@Test func localAgentGetsClaudeSessionFromPID() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data(#"{"pid":42,"sessionId":"abc-123"}"#.utf8).write(to: dir.appendingPathComponent("42.json"))
    let server = try FakeHerdrServer { _ in [
        #"{"jsonrpc":"2.0","id":"1","result":{"terminals":[{"address":"t5","foreground":{"pid":42},"status":{"state":"done"}},{"address":"box/t1","foreground":{"pid":42},"status":{"state":"done"}}]}}"#,
    ] }
    defer { server.stop() }
    let agents = try await HerdrClient(socketPath: server.path, claudeSessionsDir: dir).listAgents()
    #expect(agents.map(\.sessionID) == ["abc-123", nil])
}

@Test func serverErrorUsesKind() async throws {
    let server = try FakeHerdrServer { _ in [
        #"{"jsonrpc":"2.0","id":"1","error":{"code":-32000,"message":"no terminal \"t9\"","data":{"kind":"not_found"}}}"#,
    ] }
    defer { server.stop() }
    await #expect(throws: HerdrError.server(code: "not_found", message: "no terminal \"t9\"")) {
        try await HerdrClient(socketPath: server.path).getAgent("t9")
    }
}

@Test func getAgentParsesTerminal() async throws {
    let server = try FakeHerdrServer { _ in [#"{"jsonrpc":"2.0","id":"1","result":"# + blockedTerminal + #"}"#] }
    defer { server.stop() }
    let agent = try await HerdrClient(socketPath: server.path).getAgent("t5")
    #expect(agent.status == .blocked)
    #expect(server.requests.first?["method"] as? String == "terminal.get")
    #expect((server.requests.first?["params"] as? [String: Any])?["terminal"] as? String == "t5")
}

@Test func readRequestsScreenAndHistory() async throws {
    let server = try FakeHerdrServer { _ in [
        #"{"jsonrpc":"2.0","id":"1","result":{"text":"Do you want to proceed?"}}"#,
    ] }
    defer { server.stop() }
    let text = try await HerdrClient(socketPath: server.path).read("t5", lines: 20)
    #expect(text == "Do you want to proceed?")
    let params = server.requests.first?["params"] as? [String: Any]
    #expect(server.requests.first?["method"] as? String == "terminal.read")
    #expect(params?["terminal"] as? String == "t5")
    #expect(params?["lines"] as? Int == 20)
}

@Test func sendKeysSendsKeyList() async throws {
    let server = try FakeHerdrServer { _ in [#"{"jsonrpc":"2.0","id":"1","result":{}}"#] }
    defer { server.stop() }
    try await HerdrClient(socketPath: server.path).sendKeys("t5", ["2"])
    let params = server.requests.first?["params"] as? [String: Any]
    #expect(server.requests.first?["method"] as? String == "terminal.keys")
    #expect(params?["keys"] as? [String] == ["2"])
}

@Test func sendTextForcesPastIntoBlockedAgent() async throws {
    let server = try FakeHerdrServer { _ in [#"{"jsonrpc":"2.0","id":"1","result":{}}"#] }
    defer { server.stop() }
    try await HerdrClient(socketPath: server.path).sendText("t5", "use main")
    let params = server.requests.first?["params"] as? [String: Any]
    #expect(server.requests.first?["method"] as? String == "terminal.send")
    #expect(params?["text"] as? String == "use main")
    #expect(params?["force"] as? Bool == true)
}

@Test func promptSendsWithoutForce() async throws {
    let server = try FakeHerdrServer { _ in [#"{"jsonrpc":"2.0","id":"1","result":{}}"#] }
    defer { server.stop() }
    try await HerdrClient(socketPath: server.path).prompt("t5", "add tests")
    let params = server.requests.first?["params"] as? [String: Any]
    #expect(server.requests.first?["method"] as? String == "terminal.send")
    #expect(params?["terminal"] as? String == "t5")
    #expect(params?["text"] as? String == "add tests")
    #expect(params?["force"] == nil)
}

@Test func missingSocketThrowsSocketError() async {
    let error = await #expect(throws: HerdrError.self) {
        try await HerdrClient(socketPath: "/tmp/does-not-exist.sock").listAgents()
    }
    guard case .socket = error else {
        Issue.record("expected a socket error, got \(String(describing: error))")
        return
    }
}

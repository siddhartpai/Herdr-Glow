import Testing
import Foundation
@testable import HerdrGlowCore

private func line(_ json: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
}

@Test func parsesStatusEvent() {
    let event = HerdrEvent.parse(line(#"{"jsonrpc":"2.0","method":"event","params":{"data":{"records":{},"reported":true,"status":{"app":"claude-code","msg":"Reading","state":"working"}},"seq":430,"terminal":"t13","type":"status"}}"#))
    #expect(event == .statusChanged(paneID: "t13", status: .working))
}

@Test func statusWithoutStateIsCleared() {
    let event = HerdrEvent.parse(line(#"{"jsonrpc":"2.0","method":"event","params":{"data":{"status":null},"seq":1,"terminal":"t13","type":"status"}}"#))
    #expect(event == .statusCleared(paneID: "t13"))
}

@Test func lifecycleEventsAreTopologyChanges() {
    for type in ["created", "lost", "restarted", "finished", "removed"] {
        let object: [String: Any] = ["method": "event", "params": ["type": type, "terminal": "t1", "data": [:]]]
        #expect(HerdrEvent.parse(object) == .topologyChanged)
    }
    #expect(HerdrEvent.parse(["method": "missed", "params": [:]]) == .topologyChanged)
}

@Test func otherEventsAreIgnored() {
    #expect(HerdrEvent.parse(line(#"{"jsonrpc":"2.0","method":"event","params":{"data":{"labels":{}},"seq":425,"terminal":"t14","type":"labels"}}"#)) == nil)
    #expect(HerdrEvent.parse(line(#"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":427}}"#)) == nil)
    #expect(HerdrEvent.parse(["id": "sub", "result": ["seq": 1, "terminals": []]]) == nil)
}

@MainActor @Test func subscribeDeliversEventsThenReportsClose() async throws {
    let server = try FakeHerdrServer { _ in [
        #"{"jsonrpc":"2.0","id":"sub","result":{"seq":422,"terminals":[]}}"#,
        #"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":422}}"#,
        #"{"jsonrpc":"2.0","method":"event","params":{"data":{"status":{"app":"claude-code","state":"blocked"}},"seq":423,"terminal":"t5","type":"status"}}"#,
    ] }
    defer { server.stop() }
    let events = Box<[HerdrEvent]>([])
    let closed = Box(false)
    let sub = HerdrClient(socketPath: server.path).subscribe(
        onEvent: { events.value.append($0) },
        onClose: { _ in closed.value = true })
    #expect(await eventually { closed.value })
    #expect(events.value == [.statusChanged(paneID: "t5", status: .blocked)])
    #expect(server.requests.first?["method"] as? String == "events.subscribe")
    #expect(server.requests.first?["jsonrpc"] as? String == "2.0")
    sub.cancel()
}

@MainActor @Test func cancelDoesNotReportClose() async throws {
    let server = try FakeHerdrServer(holdOpen: 2) { _ in [
        #"{"jsonrpc":"2.0","id":"sub","result":{"seq":1,"terminals":[]}}"#,
    ] }
    defer { server.stop() }
    let closed = Box(false)
    let sub = HerdrClient(socketPath: server.path).subscribe(
        onEvent: { _ in }, onClose: { _ in closed.value = true })
    try await Task.sleep(for: .milliseconds(200))
    sub.cancel()
    try await Task.sleep(for: .milliseconds(300))
    #expect(closed.value == false)
}

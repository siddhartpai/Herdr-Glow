import Testing
import Foundation
@testable import HerdrGlowCore

private func agents(_ statuses: AgentStatus...) -> [Agent] {
    statuses.enumerated().map { Agent(paneID: "p\($0.offset)", title: "", cwd: "", status: $0.element) }
}

@Test func agentParsesFromTerminalJSON() {
    let agent = Agent(json: ["address": "t13", "title": "Fix bug", "cwd": "/tmp/shell",
                             "foreground": ["cwd": "/tmp/a", "pid": 11307],
                             "status": ["app": "claude-code", "state": "blocked"],
                             "status_ms": 1794831193584, "turn": 4])
    #expect(agent?.paneID == "t13")
    #expect(agent?.title == "Fix bug")
    #expect(agent?.cwd == "/tmp/a")
    #expect(agent?.status == .blocked)
    #expect(agent?.activity == 1794831193584)
    #expect(agent?.completion == 4)
    #expect(agent?.foregroundPID == 11307)
}

@Test func agentFallsBackToAppNameWhenTitleEmpty() {
    let agent = Agent(json: ["address": "t1", "title": "", "status": ["app": "claude-code", "state": "idle"]])
    #expect(agent?.title == "claude-code")
}

@Test func unknownStatusMapsToUnknown() {
    #expect(Agent(json: ["address": "t1", "status": ["state": "error"]])?.status == .unknown)
}

@Test func terminalWithoutStatusIsNotAnAgent() {
    #expect(Agent(json: ["address": "t1", "status": NSNull()]) == nil)
    #expect(Agent(json: ["status": ["state": "idle"]]) == nil)
}

@Test func greyWhenDisconnected() {
    #expect(LightColor.compute(connected: false, agents: agents(.blocked)) == .grey)
}

@Test func redWhenAnyBlocked() {
    #expect(LightColor.compute(connected: true, agents: agents(.working, .blocked, .done)) == .red)
}

@Test func blueWhenWorkingAndNoneBlocked() {
    #expect(LightColor.compute(connected: true, agents: agents(.working, .idle)) == .blue)
}

@Test func greenWhenAnAgentFinishedAndIsUnseen() {
    #expect(LightColor.compute(connected: true, agents: agents(.done, .idle, .unknown)) == .green)
}

@Test func calmWhenFinishedAgentWasSeen() {
    var done = Agent(paneID: "p0", title: "", cwd: "", status: .done)
    done.completion = 7
    #expect(LightColor.compute(connected: true, agents: [done], seen: ["p0": 7]) == .calm)
}

@Test func finishedBeatsWorkingButNotWaiting() {
    #expect(LightColor.compute(connected: true, agents: agents(.working, .done)) == .green)
    #expect(LightColor.compute(connected: true, agents: agents(.done, .blocked)) == .red)
}

@Test func calmWhenAllIdle() {
    #expect(LightColor.compute(connected: true, agents: agents(.idle, .unknown)) == .calm)
}

@Test func calmWhenNoAgents() {
    #expect(LightColor.compute(connected: true, agents: []) == .calm)
}

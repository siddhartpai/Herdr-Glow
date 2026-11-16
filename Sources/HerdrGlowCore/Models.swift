import Foundation

public enum AgentStatus: String, Sendable {
    case idle, working, blocked, done, unknown
}

public struct Agent: Identifiable, Equatable, Sendable {
    public var paneID: String
    public var title: String
    public var cwd: String
    public var status: AgentStatus
    /// Claude Code session id, used to find the transcript.
    public var sessionID: String?
    /// Higher means the agent's state changed more recently (herdr-core `status_ms`).
    public var activity: Int = 0
    /// Bumped each time the agent finishes a job (herdr-core `turn`).
    public var completion: Int = 0
    /// Process id of the program in the terminal, used to find its Claude Code session.
    public var foregroundPID: Int?
    public var id: String { paneID }

    public init(paneID: String, title: String, cwd: String, status: AgentStatus, sessionID: String? = nil) {
        self.paneID = paneID
        self.title = title
        self.cwd = cwd
        self.status = status
        self.sessionID = sessionID
    }

    /// Builds an agent from a herdr-core `Terminal`. Terminals whose program never
    /// reported a status are not agents.
    init?(json: [String: Any]) {
        guard let paneID = json["address"] as? String,
              let status = json["status"] as? [String: Any],
              let state = status["state"] as? String else { return nil }
        let title = json["title"] as? String
        let foreground = json["foreground"] as? [String: Any]
        self.paneID = paneID
        self.title = (title?.isEmpty == false ? title : nil) ?? (status["app"] as? String) ?? paneID
        self.cwd = foreground?["cwd"] as? String ?? json["cwd"] as? String ?? ""
        self.status = AgentStatus(rawValue: state) ?? .unknown
        self.activity = json["status_ms"] as? Int ?? 0
        self.completion = json["turn"] as? Int ?? 0
        self.foregroundPID = foreground?["pid"] as? Int
    }
}

public enum LightColor: Equatable, Sendable {
    /// grey: herdr not running. red: an agent waits. green: an agent finished and is unseen.
    /// blue: an agent works. calm: nothing needs you.
    case grey, red, green, blue, calm

    public static func compute(connected: Bool, agents: [Agent], seen: [String: Int] = [:]) -> LightColor {
        guard connected else { return .grey }
        if agents.contains(where: { $0.status == .blocked }) { return .red }
        if agents.contains(where: { $0.isUnseenFinish(seen) }) { return .green }
        if agents.contains(where: { $0.status == .working }) { return .blue }
        return .calm
    }
}

extension Agent {
    /// Finished, and this job's summary has not been seen yet.
    func isUnseenFinish(_ seen: [String: Int]) -> Bool {
        status == .done && completion > seen[paneID, default: -1]
    }
}

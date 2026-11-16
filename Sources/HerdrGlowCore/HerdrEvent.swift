import Foundation

public enum HerdrEvent: Equatable, Sendable {
    case statusChanged(paneID: String, status: AgentStatus)
    /// The program in this terminal stopped reporting a status.
    case statusCleared(paneID: String)
    /// A terminal or agent appeared or went away; the agent list must be reloaded.
    case topologyChanged

    /// herdr-core fact changes that can add or remove an agent.
    static let topologyEvents = ["created", "lost", "restarted", "finished", "removed"]

    /// Parses one herdr-core notification line (`{"method": "event", "params": {...}}`).
    public static func parse(_ object: [String: Any]) -> HerdrEvent? {
        switch object["method"] as? String {
        case "missed":
            return .topologyChanged
        case "event":
            break
        default:
            return nil
        }
        guard let params = object["params"] as? [String: Any],
              let type = params["type"] as? String else { return nil }
        if type == "status" {
            let data = params["data"] as? [String: Any] ?? [:]
            guard let paneID = params["terminal"] as? String else { return nil }
            guard let status = data["status"] as? [String: Any],
                  let state = status["state"] as? String else { return .statusCleared(paneID: paneID) }
            return .statusChanged(paneID: paneID, status: AgentStatus(rawValue: state) ?? .unknown)
        }
        return topologyEvents.contains(type) ? .topologyChanged : nil
    }
}

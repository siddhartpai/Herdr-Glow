import Foundation

public enum HerdrError: Error, Equatable, CustomStringConvertible {
    case socket(String)
    case server(code: String, message: String)
    case badResponse

    public var description: String {
        switch self {
        case .socket(let reason): "herdr connection: \(reason)"
        case .server(_, let message): message
        case .badResponse: "Unexpected response from herdr"
        }
    }

    /// Returns the error in a herdr-core `{"error": {...}}` response, or nil.
    /// The stable code is `data.kind`.
    init?(response: [String: Any]) {
        guard let error = response["error"] as? [String: Any] else { return nil }
        let data = error["data"] as? [String: Any]
        self = .server(code: data?["kind"] as? String ?? error["kind"] as? String ?? "unknown",
                       message: error["message"] as? String ?? "")
    }
}

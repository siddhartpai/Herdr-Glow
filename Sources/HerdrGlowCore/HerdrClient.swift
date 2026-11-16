import Foundation

public protocol HerdrSubscription: AnyObject, Sendable {
    func cancel()
}

public protocol HerdrAPI: Sendable {
    func listAgents() async throws -> [Agent]
    func getAgent(_ paneID: String) async throws -> Agent
    func read(_ paneID: String, lines: Int) async throws -> String
    func sendKeys(_ paneID: String, _ keys: [String]) async throws
    func sendText(_ paneID: String, _ text: String) async throws
    /// Submits a new task to an agent that is not waiting on a question.
    func prompt(_ paneID: String, _ text: String) async throws
    func focus(_ paneID: String) async throws
    func subscribe(onEvent: @escaping @Sendable (HerdrEvent) -> Void,
                   onClose: @escaping @Sendable (Error) -> Void) -> HerdrSubscription
}

/// Talks to herdr-core over its Unix socket (JSON-RPC 2.0, one message per line).
/// One connection per request.
public final class HerdrClient: HerdrAPI {
    public let socketPath: String
    /// Where Claude Code writes `<pid>.json` with the session id of each running process.
    let claudeSessionsDir: URL

    public init(socketPath: String = HerdrClient.defaultSocketPath,
                claudeSessionsDir: URL = HerdrClient.defaultClaudeSessionsDir) {
        self.socketPath = socketPath
        self.claudeSessionsDir = claudeSessionsDir
    }

    public static var defaultSocketPath: String {
        NSHomeDirectory() + "/.local/state/herdr-core/default/default.sock"
    }

    public static var defaultClaudeSessionsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions")
    }

    public func listAgents() async throws -> [Agent] {
        let result = try await call("terminal.list", [:])
        let list = result["terminals"] as? [[String: Any]] ?? []
        return list.compactMap(Agent.init(json:)).map(withSession)
    }

    public func getAgent(_ paneID: String) async throws -> Agent {
        let result = try await call("terminal.get", ["terminal": paneID])
        guard let agent = Agent(json: result) else { throw HerdrError.badResponse }
        return withSession(agent)
    }

    /// Reads the screen. `lines` is the history above it.
    public func read(_ paneID: String, lines: Int) async throws -> String {
        let result = try await call("terminal.read", ["terminal": paneID, "lines": lines])
        guard let text = result["text"] as? String else { throw HerdrError.badResponse }
        return text
    }

    public func sendKeys(_ paneID: String, _ keys: [String]) async throws {
        _ = try await call("terminal.keys", ["terminal": paneID, "keys": keys])
    }

    /// Pastes text and presses Enter, even while the agent is blocked on a question.
    public func sendText(_ paneID: String, _ text: String) async throws {
        _ = try await call("terminal.send", ["terminal": paneID, "text": text, "force": true])
    }

    public func prompt(_ paneID: String, _ text: String) async throws {
        _ = try await call("terminal.send", ["terminal": paneID, "text": text])
    }

    /// herdr-core has no focus method, so this brings the Herdr app to the front.
    public func focus(_ paneID: String) async throws {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-b", "dev.herdr.app"]
        try open.run()
    }

    /// Opens a long-lived connection for events. `onClose` is not called after `cancel()`.
    public func subscribe(onEvent: @escaping @Sendable (HerdrEvent) -> Void,
                          onClose: @escaping @Sendable (Error) -> Void) -> HerdrSubscription {
        let subscription = SocketSubscription()
        let path = socketPath
        let request: [String: Any] = ["jsonrpc": "2.0", "id": "sub", "method": "events.subscribe", "params": [:]]
        Thread {
            do {
                let socket = try LineSocket(path: path)
                defer { subscription.detach(); socket.close() }
                guard subscription.attach(socket) else { return }
                try socket.writeLine(JSONSerialization.data(withJSONObject: request))
                let started = try JSONSerialization.jsonObject(with: socket.readLine()) as? [String: Any] ?? [:]
                if let error = HerdrError(response: started) { throw error }
                while true {
                    let line = try socket.readLine()
                    if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                       let event = HerdrEvent.parse(object) {
                        onEvent(event)
                    }
                }
            } catch {
                if !subscription.isCancelled { onClose(error) }
            }
        }.start()
        return subscription
    }

    /// Adds the Claude Code session id of a local agent. Remote agents (`machine/t7`) have none here.
    private func withSession(_ agent: Agent) -> Agent {
        guard !agent.paneID.contains("/"), let pid = agent.foregroundPID else { return agent }
        let file = claudeSessionsDir.appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return agent }
        var agent = agent
        agent.sessionID = json["sessionId"] as? String
        return agent
    }

    private func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let path = socketPath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.callSync(path: path, method: method, params: params))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func callSync(path: String, method: String, params: [String: Any]) throws -> [String: Any] {
        let socket = try LineSocket(path: path)
        defer { socket.close() }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": UUID().uuidString, "method": method, "params": params]
        try socket.writeLine(JSONSerialization.data(withJSONObject: request))
        guard let response = try JSONSerialization.jsonObject(with: socket.readLine()) as? [String: Any] else {
            throw HerdrError.badResponse
        }
        if let error = HerdrError(response: response) { throw error }
        guard let result = response["result"] as? [String: Any] else { throw HerdrError.badResponse }
        return result
    }
}

final class SocketSubscription: HerdrSubscription, @unchecked Sendable {
    private let lock = NSLock()
    private var socket: LineSocket?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let socket = self.socket
        lock.unlock()
        socket?.shutdown()
    }

    /// Returns false if `cancel()` already ran.
    func attach(_ socket: LineSocket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        self.socket = socket
        return true
    }

    func detach() {
        lock.lock(); socket = nil; lock.unlock()
    }
}

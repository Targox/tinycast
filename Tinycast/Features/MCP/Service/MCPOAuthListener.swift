import Foundation
import Network

@MainActor
final class MCPOAuthListener {
    nonisolated static let redirectURI = "http://127.0.0.1:4962/callback"
    private var task: Task<Void, Never>?
    private var ready: CheckedContinuation<Void, Error>?
    private var reply: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var accepted = false

    isolated deinit { task?.cancel() }

    func start(
        state: String, issuer: String, requiresIssuer: Bool, timeout: Duration = .seconds(300)
    ) async throws {
        guard result == nil else { throw CancellationError() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                task = Task { [weak self] in
                    do {
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            group.addTask { [weak self] in
                                try await self?.serve(
                                    state: state, issuer: issuer, requiresIssuer: requiresIssuer)
                            }
                            group.addTask {
                                try await Task.sleep(for: timeout)
                                throw MCPOAuth.Failure.timedOut
                            }
                            defer { group.cancelAll() }
                            _ = try await group.next()
                        }
                    } catch {
                        self?.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func code() async throws -> String {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { reply = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<String, Error>) {
        guard self.result == nil else { return }
        self.result = result
        ready?.resume(throwing: result.failure ?? CancellationError())
        ready = nil
        reply?.resume(with: result)
        reply = nil
        task?.cancel()
        task = nil
    }

    private func serve(state: String, issuer: String, requiresIssuer: Bool) async throws {
        guard #available(macOS 26, *) else {
            return try await serveOnSequoia(state: state, issuer: issuer, requiresIssuer: requiresIssuer)
        }
        let listener = try NetworkListener(
            using: .parameters { TCP() }
                .localEndpoint(.hostPort(host: .ipv4(.loopback), port: 4962)))
        listener.newConnectionLimit = 16
        try await run(listener, state: state, issuer: issuer, requiresIssuer: requiresIssuer)
    }

    @available(macOS 26, *)
    private func run(
        _ listener: NetworkListener<TCP>, state: String, issuer: String, requiresIssuer: Bool
    ) async throws {
        try await listener.onStateUpdate { [weak self] _, status in
            switch status {
            case .ready:
                self?.ready?.resume()
                self?.ready = nil
            case .waiting, .failed:
                self?.finish(.failure(MCPOAuth.Failure.listenerUnavailable))
            default: break
            }
        }.run { [weak self] connection in
            await self?.receive(connection, state: state, issuer: issuer, requiresIssuer: requiresIssuer)
        }
    }

    @available(macOS 26, *)
    private func read(
        _ connection: NetworkConnection<TCP>, state: String, issuer: String, requiresIssuer: Bool
    ) async throws {
        var bytes = Data()
        while bytes.count < 8192 {
            let message = try await connection.receive(atLeast: 1, atMost: 8192 - bytes.count)
            bytes.append(message.content)
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            if message.metadata.endOfStream { return }
        }
        guard
            let exchange = httpExchange(
                for: bytes, state: state, issuer: issuer, requiresIssuer: requiresIssuer)
        else { return }
        let outcome = exchange.outcome
        do {
            try await connection.send(exchange.reply, endOfStream: true)
        } catch {
            if let outcome { self.finish(outcome) }
            throw error
        }
        if let outcome { self.finish(outcome) }
    }

    /// The HTTP exchange both listeners share: the page to send back and the sign-in it carried.
    private func httpExchange(
        for bytes: Data, state: String, issuer: String, requiresIssuer: Bool
    ) -> (reply: Data, outcome: Result<String, Error>?)? {
        guard !accepted else { return nil }
        guard let request = String(bytes: bytes, encoding: .utf8), request.contains("\r\n\r\n") else {
            return nil
        }
        let line = request.components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        var outcome: Result<String, Error>?
        if parts.count == 3, parts[0] == "GET" {
            do {
                let code = try MCPOAuth.callback(
                    String(parts[1]), state: state, issuer: issuer,
                    requiresIssuer: requiresIssuer)
                outcome = .success(code)
            } catch MCPOAuth.Failure.denied {
                outcome = .failure(MCPOAuth.Failure.denied)
            } catch { outcome = nil }
        }
        let status = outcome == nil ? "400 Bad Request" : "200 OK"
        let page =
            outcome == nil ? "Invalid sign-in response." : "Return to Tinycast. You can close this tab."
        let response =
            "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Cache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\n"
            + "Connection: close\r\nContent-Length: \(page.utf8.count)\r\n\r\n\(page)"
        if outcome != nil { self.accepted = true }
        return (Data(response.utf8), outcome)
    }

    @available(macOS 26, *)
    private func receive(
        _ connection: NetworkConnection<TCP>, state: String, issuer: String, requiresIssuer: Bool
    ) async {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    try await self?.read(
                        connection, state: state, issuer: issuer, requiresIssuer: requiresIssuer)
                }
                group.addTask { try await Task.sleep(for: .seconds(5)) }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch { return }
    }

    // MARK: - Sequoia

    /// Sequoia predates `NetworkListener`, so the same loopback server runs on `NWListener`.
    private func serveOnSequoia(state: String, issuer: String, requiresIssuer: Bool) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: 4962)
        let listener = try NWListener(using: parameters)
        listener.newConnectionLimit = 16
        listener.stateUpdateHandler = { [weak self] status in
            MainActor.assumeIsolated {
                switch status {
                case .ready:
                    self?.ready?.resume()
                    self?.ready = nil
                case .waiting, .failed:
                    self?.finish(.failure(MCPOAuth.Failure.listenerUnavailable))
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                self?.receiveOnSequoia(
                    connection, state: state, issuer: issuer, requiresIssuer: requiresIssuer)
            }
        }
        listener.start(queue: .main)
        defer { listener.cancel() }
        while true { try await Task.sleep(for: .seconds(3600)) }
    }

    private func receiveOnSequoia(
        _ connection: NWConnection, state: String, issuer: String, requiresIssuer: Bool
    ) {
        connection.start(queue: .main)
        Task { [weak self] in
            defer { connection.cancel() }
            try? await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    try await self?.readOnSequoia(
                        connection, state: state, issuer: issuer, requiresIssuer: requiresIssuer)
                }
                group.addTask { try await Task.sleep(for: .seconds(5)) }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        }
    }

    private func readOnSequoia(
        _ connection: NWConnection, state: String, issuer: String, requiresIssuer: Bool
    ) async throws {
        var bytes = Data()
        while bytes.count < 8192 {
            let (content, isComplete) = try await Self.receive(
                on: connection, atMost: 8192 - bytes.count)
            bytes.append(content)
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            if isComplete { return }
        }
        guard
            let exchange = httpExchange(
                for: bytes, state: state, issuer: issuer, requiresIssuer: requiresIssuer)
        else { return }
        let outcome = exchange.outcome
        do {
            try await Self.send(exchange.reply, on: connection)
        } catch {
            if let outcome { self.finish(outcome) }
            throw error
        }
        if let outcome { self.finish(outcome) }
    }

    /// Only cancelling the connection wakes a pending receive, so cancellation does that.
    private nonisolated static func receive(
        on connection: NWConnection, atMost maximum: Int
    ) async throws -> (Data, Bool) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<(Data, Bool), Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) {
                    content, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: (content ?? Data(), isComplete))
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private nonisolated static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(
                    content: data, contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    })
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

private extension Result where Success == String, Failure == Error {
    var failure: Error? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Talks to the hush-mcp binary the way an agent does: JSON-RPC lines on stdin, replies on stdout.
/// The Agents pane uses it for "Test connection", and the tests use it to check the real protocol end to end.
public enum MCPProbe {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    /// Sends every line, closes stdin so the server exits after answering, and returns the JSON objects it printed.
    /// Anything that is not a JSON object on stdout is returned as a failure: stdout carries protocol messages only.
    public static func exchange(server: String, lines: [String], env: [String: String] = [:], timeout: TimeInterval = 30) async throws -> [JSON] {
        guard FileManager.default.isExecutableFile(atPath: server) else {
            throw TDError(code: 0, message: "The MCP server was not found at \(server).")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: server)
        p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        let out = Collector()
        outPipe.fileHandleForReading.readabilityHandler = { out.append($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { _ = $0.availableData }   // drain so the server never blocks on stderr
        try p.run()
        inPipe.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try? inPipe.fileHandleForWriting.close()

        let finished: Bool = await withCheckedContinuation { cont in
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
            DispatchQueue.global().async {
                if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); cont.resume(returning: false) } else { cont.resume(returning: true) }
            }
        }
        try? await Task.sleep(for: .milliseconds(50))   // let the last readability callback land
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        guard finished else { throw TDError(code: 0, message: "The MCP server did not answer in \(Int(timeout)) seconds.") }

        return try out.string.split(whereSeparator: \.isNewline).map { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSON else {
                throw TDError(code: 0, message: "The MCP server printed something that is not a JSON message: \(line.prefix(80))")
            }
            return obj
        }
    }

    public struct Report: Equatable, Sendable {
        public enum Level: Equatable, Sendable { case ok, appProblem, broken }
        public var level: Level
        public var message: String
        public var ok: Bool { level == .ok }
    }

    /// A real handshake: initialize, list the tools, ask Hush for its status.
    public static func run(server: String, env: [String: String] = [:]) async -> Report {
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"hush-test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"hush_status","arguments":{}}}"#,
        ]
        let replies: [JSON]
        do { replies = try await exchange(server: server, lines: lines, env: env, timeout: 40) }
        catch { return Report(level: .broken, message: error.localizedDescription) }
        func reply(_ id: Int) -> JSON? { replies.first { $0.int("id") == Int64(id) } }

        guard reply(1)?.obj("result") != nil else { return Report(level: .broken, message: "The MCP server did not answer the handshake.") }
        let tools = (reply(2)?.obj("result")?["tools"] as? [JSON])?.compactMap { $0.str("name") } ?? []
        guard tools.contains("hush_status"), tools.contains("hush_read") else { return Report(level: .broken, message: "The MCP server listed no Hush tools.") }
        guard let call = reply(3)?.obj("result") else { return Report(level: .broken, message: "The MCP server did not answer the status request.") }
        let text = ((call["content"] as? [JSON])?.first?.str("text")) ?? ""
        if call.bool("isError") { return Report(level: .appProblem, message: "The server works, but Hush said: \(text)") }
        return Report(level: .ok, message: "Working. \(tools.count) tools available. \(text)")
    }
}

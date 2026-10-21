// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin

/// How the MCP server reaches the running app: one JSON object per line over an owner-only Unix socket.
/// Only one process may own Telegram's database, so the app does the work and the MCP server asks it.
private func socketAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        for (i, b) in bytes.enumerated() { dst[i] = UInt8(bitPattern: b) }
    }
    return addr
}

private func readLine(_ fd: Int32) -> Data? {
    var buf = Data(); var byte: UInt8 = 0
    while buf.count < 1_000_000 {
        let n = read(fd, &byte, 1)
        if n <= 0 { return buf.isEmpty ? nil : buf }
        if byte == 10 { return buf }
        buf.append(byte)
    }
    return nil
}

private func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        var off = 0
        while off < raw.count {
            let n = write(fd, raw.baseAddress! + off, raw.count - off)
            if n <= 0 { return }
            off += n
        }
    }
}

public final class ControlServer: @unchecked Sendable {
    private let path: String
    private let handler: @Sendable (JSON) async -> JSON
    private var fd: Int32 = -1

    public init(path: String, handler: @escaping @Sendable (JSON) async -> JSON) { self.path = path; self.handler = handler }

    public func start() throws {
        unlink(path)
        guard var addr = socketAddress(path) else { throw TDError(code: 0, message: "Socket path too long.") }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let old = umask(0o177)                                   // owner-only from the first instant
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        umask(old)
        guard ok == 0, listen(fd, 8) == 0 else { throw TDError(code: Int(errno), message: "Could not open the agent socket.") }
        chmod(path, 0o600)
        let listenFd = fd
        let t = Thread { [handler] in
            while true {
                let c = accept(listenFd, nil, nil)
                if c < 0 { return }
                Task.detached {
                    defer { close(c) }
                    guard let line = readLine(c), let req = (try? JSONSerialization.jsonObject(with: line)) as? JSON else { return }
                    let res = await handler(req)
                    if let d = try? JSONSerialization.data(withJSONObject: res) { writeAll(c, d + Data([10])) }
                }
            }
        }
        t.name = "hush.control"; t.qualityOfService = .utility; t.start()
    }

    public func stop() { if fd >= 0 { close(fd); fd = -1 }; unlink(path) }
}

public enum ControlClient {
    /// One request, one reply. `timeout` covers the whole call, including a human approval.
    public static func call(_ request: JSON, socket: String = AppPaths().socketFile.path, timeout: TimeInterval = 130) throws -> JSON {
        guard var addr = socketAddress(socket) else { throw TDError(code: 0, message: "Socket path too long.") }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0 else { throw TDError(code: Int(errno), message: "Hush is not running.") }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        writeAll(fd, try JSONSerialization.data(withJSONObject: request) + Data([10]))
        guard let line = readLine(fd), let res = (try? JSONSerialization.jsonObject(with: line)) as? JSON else {
            throw TDError(code: 0, message: "Hush did not answer.")
        }
        return res
    }

    public static func isUp(socket: String = AppPaths().socketFile.path) -> Bool {
        (try? call(["op": "ping"], socket: socket, timeout: 3))?.bool("ok") == true
    }

    /// Starts the app in the background (no window, no focus) and waits for its socket.
    public static func launchAppIfNeeded(bundleId: String = "com.kalahroudi.hush", wait: TimeInterval = 20, socket: String = AppPaths().socketFile.path) -> Bool {
        if isUp(socket: socket) { return true }
        if ProcessInfo.processInfo.environment["HUSH_NO_LAUNCH"] != nil { return false }   // tests must never start the real app
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-g", "-j", "-b", bundleId]
        try? p.run(); p.waitUntilExit()
        let end = Date().addingTimeInterval(wait)
        while Date() < end { if isUp(socket: socket) { return true }; Thread.sleep(forTimeInterval: 0.4) }
        return false
    }
}

/// The native confirmation an agent's message must pass. Denies on timeout, on cancel and on any error.
public enum Approval {
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
    }

    public static func script(chat: String, text: String, timeout: Int = 90) -> String {
        let shown = text.count > 1200 ? String(text.prefix(1200)) + "…" : text
        let msg = "An AI agent wants to send this message as you.\\n\\nTo: \(escape(chat))\\n\\n\(escape(shown))"
        return "display dialog \"\(msg)\" with title \"Hush\" buttons {\"Deny\", \"Send\"} default button \"Deny\" cancel button \"Deny\" with icon caution giving up after \(timeout)"
    }

    /// Allow only if the user pressed Send and the dialog did not time out.
    public static func allowed(output: String) -> Bool { output.contains("button returned:Send") && !output.contains("gave up:true") }

    public static func ask(chat: String, text: String) async -> Bool {
        guard let out = try? await Shell.run("osascript", ["-e", script(chat: chat, text: text)], timeout: 100) else { return false }
        return allowed(output: out.stdout)
    }
}

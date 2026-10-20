// SPDX-License-Identifier: Apache-2.0

import Foundation

public typealias JSON = [String: Any]

public struct TDError: LocalizedError {
    public let code: Int
    public let message: String
    public var errorDescription: String? { message }
}

/// TDLib's C JSON interface, loaded at runtime with dlopen. Hush links nothing at build time,
/// so the app stays small and the library is found wherever it is installed (Homebrew by default).
public final class TDLib: @unchecked Sendable {
    typealias CreateClientId = @convention(c) () -> Int32
    typealias SendFn = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void
    typealias ReceiveFn = @convention(c) (Double) -> UnsafePointer<CChar>?
    typealias ExecuteFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?

    let createClientId: CreateClientId
    let sendFn: SendFn
    let receiveFn: ReceiveFn
    let executeFn: ExecuteFn
    public let path: String

    public static func candidates(root: URL = AppPaths().root) -> [String] {
        [Bundle.main.bundlePath + "/Contents/Frameworks/libtdjson.dylib",
         root.appendingPathComponent("lib/libtdjson.dylib").path,
         "/opt/homebrew/opt/tdlib/lib/libtdjson.dylib", "/usr/local/opt/tdlib/lib/libtdjson.dylib",
         "/opt/homebrew/lib/libtdjson.dylib", "/usr/local/lib/libtdjson.dylib"]
    }

    /// Telegram refuses to sign in from old TDLib builds (UPDATE_APP_TO_LOGIN). Homebrew still ships 1.8.0 from 2021.
    public static let minimumVersion = "1.8.60"

    nonisolated(unsafe) private static var cached: TDLib??
    private static let cacheLock = NSLock()

    /// The first installed library that is new enough, loaded once. Cheap after the first call, so setup can ask on every refresh.
    public static func load() -> TDLib? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = cached, c != nil { return c }
        for path in candidates() where FileManager.default.fileExists(atPath: path) {
            if let lib = TDLib(path: path), let v = lib.version, versionAtLeast(v, minimumVersion) { cached = .some(lib); return lib }
        }
        return nil   // not cached: a library installed a moment later is picked up on the next call
    }

    public static func versionAtLeast(_ v: String, _ minimum: String) -> Bool {
        let a = v.split(separator: ".").map { Int($0) ?? 0 }, b = minimum.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    public var version: String? {
        execute(["@type": "getOption", "name": "version"])?.str("value")
    }

    public init?(path p: String) {
        guard let h = dlopen(p, RTLD_NOW | RTLD_LOCAL),
              let a = dlsym(h, "td_create_client_id"), let b = dlsym(h, "td_send"),
              let c = dlsym(h, "td_receive"), let d = dlsym(h, "td_execute") else { return nil }
        createClientId = unsafeBitCast(a, to: CreateClientId.self)
        sendFn = unsafeBitCast(b, to: SendFn.self)
        receiveFn = unsafeBitCast(c, to: ReceiveFn.self)
        executeFn = unsafeBitCast(d, to: ExecuteFn.self)
        self.path = p
    }

    /// Synchronous requests that need no client (log settings, version).
    public func execute(_ request: JSON) -> JSON? {
        guard let data = try? JSONSerialization.data(withJSONObject: request), let s = String(data: data, encoding: .utf8) else { return nil }
        return s.withCString { p in
            guard let r = executeFn(p) else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(String(cString: r).utf8))) as? JSON
        }
    }
}

/// One TDLib client: a receive thread, request/response matching by `@extra`, and an update callback.
public final class TDClient: @unchecked Sendable {
    private let lib: TDLib
    private var clientId: Int32 = 0
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var nextExtra = 1
    private var stopped = false
    /// Called on the receive thread for every update (not for responses).
    public var onUpdate: (@Sendable (JSON) -> Void)?

    public init(lib: TDLib) { self.lib = lib }

    public func start() {
        _ = lib.execute(["@type": "setLogVerbosityLevel", "new_verbosity_level": 0])   // no log file, nothing on stderr
        clientId = lib.createClientId()
        let t = Thread { [self] in receiveLoop() }
        t.name = "hush.td"; t.qualityOfService = .utility; t.start()
        send(["@type": "getOption", "name": "version"])   // the first request wakes the client up
    }

    public func stop() { lock.lock(); stopped = true; lock.unlock() }

    public func send(_ request: JSON) {
        guard let data = try? JSONSerialization.data(withJSONObject: request), let s = String(data: data, encoding: .utf8) else { return }
        s.withCString { lib.sendFn(clientId, $0) }
    }

    @discardableResult
    public func request(_ req: JSON, timeout: TimeInterval = 30) async throws -> JSON {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSON, Error>) in
            lock.lock(); let extra = nextExtra; nextExtra += 1; pending[extra] = c; lock.unlock()
            var r = req; r["@extra"] = extra
            send(r)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                lock.lock(); let c = pending.removeValue(forKey: extra); lock.unlock()
                c?.resume(throwing: TDError(code: 408, message: "Telegram did not answer in time. Check your connection."))
            }
        }
    }

    private func receiveLoop() {
        while true {
            lock.lock(); let done = stopped; lock.unlock()
            if done { return }
            guard let p = lib.receiveFn(5.0) else { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(String(cString: p).utf8))) as? JSON else { continue }
            if let extra = obj["@extra"] as? Int {
                lock.lock(); let c = pending.removeValue(forKey: extra); lock.unlock()
                if (obj["@type"] as? String) == "error" {
                    c?.resume(throwing: TDError(code: obj["code"] as? Int ?? 0, message: obj["message"] as? String ?? "Telegram error"))
                } else { c?.resume(returning: obj) }
            } else { onUpdate?(obj) }
        }
    }
}

// MARK: JSON accessors (TDLib sends int64 as strings and int53 as numbers)

public extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { self[k] as? String }
    func obj(_ k: String) -> JSON? { self[k] as? JSON }
    func arr(_ k: String) -> [JSON] { self[k] as? [JSON] ?? [] }
    func int(_ k: String) -> Int64? {
        switch self[k] {
        case let v as Int64: v
        case let v as Int: Int64(v)
        case let v as Double: Int64(v)
        case let v as String: Int64(v)
        case let v as NSNumber: v.int64Value
        default: nil
        }
    }
    func bool(_ k: String) -> Bool { self[k] as? Bool ?? false }
    var type: String { self["@type"] as? String ?? "" }
}

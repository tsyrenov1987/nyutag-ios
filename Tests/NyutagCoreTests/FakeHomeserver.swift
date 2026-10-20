// Поддельный домашний сервер в памяти для тестов шифрования: ключи устройств, одноразовые ключи,
// to-device, участники и события комнат, бэкап ключей. Подключается к MatrixClient через URLProtocol.

import Foundation
@testable import NyutagCore

final class FakeHomeserver: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: FakeHomeserver] = [:]

    static func server(host: String) -> FakeHomeserver? { lock.withLock { servers[host] } }

    let host = "fake-\(UUID().uuidString.lowercased())"
    var homeserver: URL { URL(string: "http://\(host)")! }

    private let lock = NSLock()
    private var tokens: [String: (user: String, device: String)] = [:]
    private var deviceKeys: [String: [String: JSONValue]] = [:]
    private var oneTimeKeys: [String: [(id: String, key: JSONValue)]] = [:]
    private var fallbackKeys: [String: (id: String, key: JSONValue)] = [:]
    private var inbox: [String: [JSONValue]] = [:]
    private var members: [String: Set<String>] = [:]
    private var timeline: [String: [JSONValue]] = [:]
    private(set) var backup: [String: [String: JSONValue]] = [:]
    private var nextEvent = 0
    /// Ключи кросс-подписи: пользователь → usage → объект.
    private var crossSigning: [String: [String: JSONValue]] = [:]
    /// Требовать подтверждение паролем для `/keys/device_signing/upload`.
    var requirePassword: String?
    /// Подмена ответа `/keys/query` для проверки подписей.
    var tamperDeviceKeys: ((String, String, JSONValue) -> JSONValue)?

    init() { Self.lock.withLock { Self.servers[host] = self } }

    deinit { Self.lock.withLock { _ = Self.servers.removeValue(forKey: host) } }

    func session(user: String, device: String) -> Session {
        let token = "tok-\(user)-\(device)"
        lock.withLock { tokens[token] = (user, device) }
        return Session(userID: user, deviceID: device, accessToken: token, homeserver: homeserver)
    }

    func client(for session: Session) -> MatrixClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeHomeserverProtocol.self]
        return MatrixClient(homeserver: homeserver, accessToken: session.accessToken, configuration: configuration)
    }

    func setMembers(_ users: [String], roomID: String) { lock.withLock { members[roomID] = Set(users) } }

    /// Забрать накопившиеся to-device события устройства.
    func takeToDevice(user: String, device: String) -> [Event] {
        lock.withLock {
            let events = inbox.removeValue(forKey: "\(user)|\(device)") ?? []
            return events.compactMap(Event.init(json:))
        }
    }

    func events(roomID: String) -> [Event] {
        lock.withLock { (timeline[roomID] ?? []).compactMap(Event.init(json:)) }
    }

    /// Устройство осталось без одноразовых и запасного ключа.
    func dropOneTimeKeys(user: String, device: String) {
        lock.withLock {
            oneTimeKeys["\(user)|\(device)"] = nil
            fallbackKeys["\(user)|\(device)"] = nil
        }
    }

    func oneTimeKeyCount(user: String, device: String) -> Int {
        lock.withLock { oneTimeKeys["\(user)|\(device)"]?.count ?? 0 }
    }

    // MARK: Обработка запроса

    func handle(method: String, path: [String], query: [String: String], body: JSONValue?,
                token: String?) -> (Int, JSONValue) {
        lock.withLock {
            guard let token, let who = tokens[token] else {
                return (401, ["errcode": "M_UNKNOWN_TOKEN", "error": "нет токена"])
            }
            switch (method, path) {
            case ("POST", ["keys", "upload"]):
                if let keys = body?["device_keys"] { deviceKeys[who.user, default: [:]][who.device] = keys }
                for (id, key) in body?["one_time_keys"]?.object ?? [:] {
                    oneTimeKeys["\(who.user)|\(who.device)", default: []].append((id, key))
                }
                for (id, key) in body?["fallback_keys"]?.object ?? [:] { fallbackKeys["\(who.user)|\(who.device)"] = (id, key) }
                let count = oneTimeKeys["\(who.user)|\(who.device)"]?.count ?? 0
                return (200, ["one_time_key_counts": ["signed_curve25519": .int(count)]])

            case ("POST", ["keys", "query"]):
                var result: [String: JSONValue] = [:]
                for user in body?["device_keys"]?.object?.keys.sorted() ?? [] {
                    var devices: [String: JSONValue] = [:]
                    for (device, keys) in deviceKeys[user] ?? [:] {
                        devices[device] = tamperDeviceKeys?(user, device, keys) ?? keys
                    }
                    result[user] = .object(devices)
                }
                var response: [String: JSONValue] = ["device_keys": .object(result), "failures": [:]]
                for (usage, field) in [("master", "master_keys"), ("self_signing", "self_signing_keys"),
                                       ("user_signing", "user_signing_keys")] {
                    var keys: [String: JSONValue] = [:]
                    for user in result.keys {
                        // Ключ подписи пользователей виден только его владельцу.
                        if usage == "user_signing", user != who.user { continue }
                        if let key = crossSigning[user]?[usage] { keys[user] = key }
                    }
                    response[field] = .object(keys)
                }
                return (200, .object(response))

            case ("POST", ["keys", "device_signing", "upload"]):
                if let password = requirePassword {
                    guard body?["auth", "password"]?.string == password, body?["auth", "session"]?.string == "uia1" else {
                        return (401, ["flows": [["stages": ["m.login.password"]]], "params": [:], "session": "uia1"])
                    }
                }
                for (usage, field) in [("master", "master_key"), ("self_signing", "self_signing_key"),
                                       ("user_signing", "user_signing_key")] {
                    if let key = body?[field] { crossSigning[who.user, default: [:]][usage] = key }
                }
                return (200, [:])

            case ("POST", ["keys", "signatures", "upload"]):
                for (user, keys) in body?.object ?? [:] {
                    for (keyID, signed) in keys.object ?? [:] {
                        let added = signed["signatures", user]?.object ?? [:]
                        func merge(_ target: JSONValue) -> JSONValue {
                            guard case .object(var fields) = target else { return target }
                            var signatures = fields["signatures"]?.object ?? [:]
                            var mine = signatures[user]?.object ?? [:]
                            for (id, value) in added { mine[id] = value }
                            signatures[user] = .object(mine)
                            fields["signatures"] = .object(signatures)
                            return .object(fields)
                        }
                        if let device = deviceKeys[user]?[keyID] {
                            deviceKeys[user]?[keyID] = merge(device)
                        } else if let master = crossSigning[user]?["master"], master["keys", "ed25519:\(keyID)"] != nil {
                            crossSigning[user]?["master"] = merge(master)
                        }
                    }
                }
                return (200, ["failures": [:]])

            case ("POST", ["keys", "claim"]):
                var result: [String: JSONValue] = [:]
                for (user, devices) in body?["one_time_keys"]?.object ?? [:] {
                    var claimed: [String: JSONValue] = [:]
                    for device in devices.object?.keys.sorted() ?? [] {
                        let slot = "\(user)|\(device)"
                        if var keys = oneTimeKeys[slot], !keys.isEmpty {
                            let key = keys.removeFirst()
                            oneTimeKeys[slot] = keys
                            claimed[device] = .object([key.id: key.key])
                        } else if let fallback = fallbackKeys[slot] {
                            claimed[device] = .object([fallback.id: fallback.key])
                        }
                    }
                    result[user] = .object(claimed)
                }
                return (200, ["one_time_keys": .object(result), "failures": [:]])

            case ("PUT", let p) where p.count == 3 && p[0] == "sendToDevice":
                for (user, devices) in body?["messages"]?.object ?? [:] {
                    for (device, content) in devices.object ?? [:] {
                        let targets = device == "*" ? Array((deviceKeys[user] ?? [:]).keys) : [device]
                        for target in targets {
                            inbox["\(user)|\(target)", default: []].append(
                                ["type": .string(p[1]), "sender": .string(who.user), "content": content])
                        }
                    }
                }
                return (200, [:])

            case ("GET", let p) where p.count == 3 && p[0] == "rooms" && p[2] == "members":
                let chunk = (members[p[1]] ?? []).sorted().map { user -> JSONValue in
                    ["type": "m.room.member", "state_key": .string(user), "sender": .string(user),
                     "event_id": .string("$member-\(user)"), "content": ["membership": "join"]]
                }
                return (200, ["chunk": .array(chunk)])

            case ("PUT", let p) where p.count == 5 && p[0] == "rooms" && p[2] == "send":
                nextEvent += 1
                let eventID = "$e\(nextEvent)"
                timeline[p[1], default: []].append([
                    "type": .string(p[3]), "event_id": .string(eventID), "sender": .string(who.user),
                    "origin_server_ts": .int(nextEvent), "room_id": .string(p[1]), "content": body ?? [:],
                ])
                return (200, ["event_id": .string(eventID)])

            case ("PUT", ["room_keys", "keys"]):
                guard query["version"] == "1" else {
                    return (403, ["errcode": "M_WRONG_ROOM_KEYS_VERSION", "error": "версия", "current_version": "1"])
                }
                for (room, entry) in body?["rooms"]?.object ?? [:] {
                    for (session, record) in entry["sessions"]?.object ?? [:] { backup[room, default: [:]][session] = record }
                }
                return (200, ["count": .int(backup.values.map(\.count).reduce(0, +)), "etag": "1"])

            default:
                return (404, ["errcode": "M_UNRECOGNIZED", "error": .string("\(method) \(path.joined(separator: "/"))")])
            }
        }
    }
}

final class FakeHomeserverProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let server = FakeHomeserver.server(host: url.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            bodyData = data
        }
        let body = bodyData.flatMap { $0.isEmpty ? nil : try? JSONValue(data: $0) }
        // /_matrix/client/v3/<путь>
        let path = Array(url.path.split(separator: "/").map(String.init).dropFirst(3))
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { first, _ in first })
        let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
        let (status, json) = server.handle(method: request.httpMethod ?? "GET", path: path, query: query, body: body,
                                           token: token)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? json.data()) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

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
    /// Текущая версия бэкапа и её `auth_data`; nil — версия «1» без описания (её не видно по GET).
    private(set) var backupVersion = "1"
    private(set) var backupAuthData: JSONValue?
    /// Account data: пользователь → тип → содержимое.
    private var accountData: [String: [String: JSONValue]] = [:]
    private var nextEvent = 0
    /// Удалённые аккаунты и жалобы на события.
    private(set) var deactivated: Set<String> = []
    private(set) var erased = false
    /// Имена устройств из `PUT /devices/{id}`.
    private var deviceNames: [String: String] = [:]
    private(set) var reports: [(user: String, roomID: String, eventID: String, reason: String, score: Int)] = []
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

    /// Пароли для `m.login.password`: пользователь → пароль.
    private var passwords: [String: String] = [:]
    private var loginCount = 0

    func setPassword(_ password: String, user: String) { lock.withLock { passwords[user] = password } }

    func isTokenValid(_ token: String) -> Bool { lock.withLock { tokens[token] != nil } }

    /// Пушеры по пользователю: ключ — app_id и pushkey, как на настоящем сервере.
    private var pusherTable: [String: [String: JSONValue]] = [:]
    private var pushRules: [String: JSONValue] = [:]
    func pushers(user: String) -> [JSONValue] { lock.withLock { Array(pusherTable[user, default: [:]].values) } }
    func pushRule(user: String, kind: String, id: String) -> JSONValue? { lock.withLock { pushRules["\(user)|\(kind)|\(id)"] } }

    /// Клиент с любым токеном или без него (для входа).
    func client(accessToken: String?) -> MatrixClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeHomeserverProtocol.self]
        return MatrixClient(homeserver: homeserver, accessToken: accessToken, configuration: configuration)
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

    func crossSigningKey(user: String, usage: String) -> JSONValue? { lock.withLock { crossSigning[user]?[usage] } }

    func accountDataContent(user: String, type: String) -> JSONValue? { lock.withLock { accountData[user]?[type] } }

    func oneTimeKeyCount(user: String, device: String) -> Int {
        lock.withLock { oneTimeKeys["\(user)|\(device)"]?.count ?? 0 }
    }

    // MARK: Обработка запроса

    func handle(method: String, path: [String], query: [String: String], body: JSONValue?,
                token: String?) -> (Int, JSONValue) {
        lock.withLock {
            if method == "POST", path == ["login"] {
                guard let user = body?["identifier", "user"]?.string, let password = body?["password"]?.string else {
                    return (400, ["errcode": "M_BAD_JSON", "error": "нет логина"])
                }
                let userID = user.hasPrefix("@") ? user : "@\(user):nyutag.chat"
                guard passwords[userID] == password else { return (403, ["errcode": "M_FORBIDDEN", "error": "пароль"]) }
                loginCount += 1
                let device = body?["device_id"]?.string ?? "DEV\(loginCount)"
                let token = "tok-\(userID)-\(device)-\(loginCount)"
                tokens[token] = (userID, device)
                return (200, ["user_id": .string(userID), "access_token": .string(token), "device_id": .string(device)])
            }
            guard let token, let who = tokens[token] else {
                return (401, ["errcode": "M_UNKNOWN_TOKEN", "error": "нет токена"])
            }
            switch (method, path) {
            case ("GET", ["account", "whoami"]):
                return (200, ["user_id": .string(who.user), "device_id": .string(who.device)])
            case ("POST", ["logout"]):
                tokens[token] = nil
                return (200, [:])
            case ("GET", ["devices"]):
                let list = Set(tokens.values.filter { $0.user == who.user }.map(\.device)).sorted().map { device -> JSONValue in
                    var item: [String: JSONValue] = ["device_id": .string(device)]
                    if let name = deviceNames[device] { item["display_name"] = .string(name) }
                    return .object(item)
                }
                return (200, ["devices": .array(list)])
            case ("PUT", let p) where p.count == 2 && p[0] == "devices":
                guard tokens.values.contains(where: { $0.user == who.user && $0.device == p[1] }) else {
                    return (404, ["errcode": "M_NOT_FOUND", "error": "нет устройства"])
                }
                deviceNames[p[1]] = body?["display_name"]?.string
                return (200, [:])
            case ("DELETE", let p) where p.count == 2 && p[0] == "devices":
                guard let password = passwords[who.user], body?["auth", "password"]?.string == password,
                      body?["auth", "session"]?.string == "uia-device" else {
                    return (401, ["flows": [["stages": ["m.login.password"]]], "params": [:], "session": "uia-device"])
                }
                for (key, value) in tokens where value.user == who.user && value.device == p[1] { tokens[key] = nil }
                return (200, [:])
            case ("POST", ["account", "deactivate"]):
                // Подтверждение паролем, как у настоящего сервера.
                guard let password = passwords[who.user], body?["auth", "password"]?.string == password,
                      body?["auth", "session"]?.string == "uia-deactivate" else {
                    return (401, ["flows": [["stages": ["m.login.password"]]], "params": [:], "session": "uia-deactivate"])
                }
                deactivated.insert(who.user)
                erased = body?["erase"]?.bool == true
                for (key, value) in tokens where value.user == who.user { tokens[key] = nil }
                return (200, ["id_server_unbind_result": "no-support"])
            case ("POST", let p) where p.count == 4 && p[0] == "rooms" && p[2] == "report":
                reports.append((who.user, p[1], p[3], body?["reason"]?.string ?? "", body?["score"]?.int ?? 0))
                return (200, [:])
            case ("POST", ["pushers", "set"]):
                guard let appID = body?["app_id"]?.string, let pushKey = body?["pushkey"]?.string else {
                    return (400, ["errcode": "M_MISSING_PARAM", "error": "нет app_id/pushkey"])
                }
                pusherTable[who.user, default: [:]]["\(appID)|\(pushKey)"] = body?["kind"] == .null ? nil : body
                return (200, [:])
            case ("PUT", let p) where p.count == 4 && p[0] == "pushrules" && p[1] == "global":
                pushRules["\(who.user)|\(p[2])|\(p[3])"] = body
                return (200, [:])
            case ("DELETE", let p) where p.count == 4 && p[0] == "pushrules" && p[1] == "global":
                guard pushRules.removeValue(forKey: "\(who.user)|\(p[2])|\(p[3])") != nil else {
                    return (404, ["errcode": "M_NOT_FOUND", "error": "нет правила"])
                }
                return (200, [:])
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
                        // Подписать чужой ключ может кто угодно (мастер-ключ собеседника — ключом подписи пользователей).
                        let added = signed["signatures"]?.object ?? [:]
                        func merge(_ target: JSONValue) -> JSONValue {
                            guard case .object(var fields) = target else { return target }
                            var signatures = fields["signatures"]?.object ?? [:]
                            for (signer, entries) in added {
                                var theirs = signatures[signer]?.object ?? [:]
                                for (id, value) in entries.object ?? [:] { theirs[id] = value }
                                signatures[signer] = .object(theirs)
                            }
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

            case ("GET", let p) where p.count == 4 && p[0] == "rooms" && p[2] == "event":
                guard let event = (timeline[p[1]] ?? []).first(where: { $0["event_id"]?.string == p[3] }) else {
                    return (404, ["errcode": "M_NOT_FOUND", "error": "нет события"])
                }
                return (200, event)

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
                    "origin_server_ts": .int(Int(Date().timeIntervalSince1970 * 1000)), "room_id": .string(p[1]), "content": body ?? [:],
                ])
                return (200, ["event_id": .string(eventID)])

            case ("PUT", let p) where p.count == 4 && p[0] == "user" && p[2] == "account_data":
                guard p[1] == who.user else { return (403, ["errcode": "M_FORBIDDEN", "error": "чужой"]) }
                accountData[who.user, default: [:]][p[3]] = body ?? [:]
                return (200, [:])

            case ("GET", let p) where p.count == 4 && p[0] == "user" && p[2] == "account_data":
                guard p[1] == who.user, let content = accountData[who.user]?[p[3]] else {
                    return (404, ["errcode": "M_NOT_FOUND", "error": "нет"])
                }
                return (200, content)

            case ("POST", ["room_keys", "version"]):
                backupVersion = String((Int(backupVersion) ?? 0) + 1)
                backupAuthData = body?["auth_data"]
                backup = [:]
                return (200, ["version": .string(backupVersion)])

            case ("GET", ["room_keys", "version"]):
                guard let authData = backupAuthData else { return (404, ["errcode": "M_NOT_FOUND", "error": "нет бэкапа"]) }
                return (200, ["version": .string(backupVersion), "algorithm": "m.megolm_backup.v1.curve25519-aes-sha2",
                              "auth_data": authData, "count": .int(backup.values.map(\.count).reduce(0, +)), "etag": "1"])

            case ("GET", ["room_keys", "keys"]):
                guard query["version"] == backupVersion else {
                    return (404, ["errcode": "M_NOT_FOUND", "error": "версия"])
                }
                return (200, ["rooms": .object(backup.mapValues { ["sessions": .object($0)] })])

            case ("PUT", ["room_keys", "keys"]):
                guard query["version"] == backupVersion else {
                    return (403, ["errcode": "M_WRONG_ROOM_KEYS_VERSION", "error": "версия",
                                  "current_version": .string(backupVersion)])
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

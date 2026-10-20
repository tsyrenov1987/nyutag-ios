// Нютаг. HTTP-слой клиент-серверного API Matrix поверх URLSession.
// Транспорт (SOCKS кильватера, доверие своему CA) задаёт приложение через URLSessionConfiguration и делегат,
// движок о нём не знает: на Маке тесты ходят в ядро по проброшенному порту без всякого туннеля.

import Foundation

public struct MatrixError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Сервер ответил ошибкой Matrix (`errcode` + `error`).
        case server(status: Int, errcode: String, message: String)
        /// Сервер ответил не JSON-ошибкой (например, 502 от прокси).
        case http(status: Int)
        case network(String)
        case decoding(String)
        case noAccessToken
        case cancelled
    }

    public let kind: Kind
    /// Пауза перед повтором для `M_LIMIT_EXCEEDED`.
    public let retryAfter: Duration?

    public init(_ kind: Kind, retryAfter: Duration? = nil) {
        self.kind = kind
        self.retryAfter = retryAfter
    }

    public var errcode: String? {
        if case .server(_, let errcode, _) = kind { return errcode }
        return nil
    }

    public var status: Int? {
        switch kind {
        case .server(let status, _, _), .http(let status): return status
        default: return nil
        }
    }

    public var isUnknownToken: Bool { errcode == "M_UNKNOWN_TOKEN" }
}

public struct EmptyResponse: Decodable, Sendable {}

/// Один сеанс запросов к домашнему серверу. Актор: токен доступа меняется при входе и выходе.
public actor MatrixClient {
    public static let apiVersion = "v3"

    public nonisolated let homeserver: URL
    public private(set) var accessToken: String?
    nonisolated let session: URLSession
    nonisolated let userAgent: String

    /// Повторы при 429: не больше этого числа, и не дольше суммарно `maxRetryWait`.
    var maxRateLimitRetries = 4
    var maxRetryWait: Duration = .seconds(30)

    public init(homeserver: URL,
                accessToken: String? = nil,
                configuration: URLSessionConfiguration = MatrixClient.defaultConfiguration(),
                delegate: URLSessionDelegate? = nil,
                userAgent: String = "Nyutag") {
        self.homeserver = homeserver
        self.accessToken = accessToken
        self.userAgent = userAgent
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        configuration.urlCache = nil
        return configuration
    }

    public func setAccessToken(_ token: String?) {
        accessToken = token
    }

    // MARK: Запросы

    /// Запрос к `/_matrix/client/<version>/<path>`.
    public func request<Response: Decodable & Sendable>(_ method: Method,
                                                        _ path: String,
                                                        version: String = MatrixClient.apiVersion,
                                                        query: [String: String] = [:],
                                                        body: JSONValue? = nil,
                                                        authenticated: Bool = true,
                                                        timeout: Duration? = nil) async throws(MatrixError) -> Response {
        try await raw(method, "/_matrix/client/\(version)/\(path)", query: query, body: body,
                      authenticated: authenticated, timeout: timeout)
    }

    /// Запрос по произвольному пути сервера (`/_nyutag/v1/...`, `/_matrix/media/...`).
    public func raw<Response: Decodable & Sendable>(_ method: Method,
                                                    _ absolutePath: String,
                                                    query: [String: String] = [:],
                                                    body: JSONValue? = nil,
                                                    authenticated: Bool = true,
                                                    timeout: Duration? = nil) async throws(MatrixError) -> Response {
        let data = try await data(method, absolutePath, query: query, body: body,
                                  authenticated: authenticated, timeout: timeout)
        if Response.self == EmptyResponse.self, let empty = EmptyResponse() as? Response {
            return empty
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw MatrixError(.decoding("\(absolutePath): \(error)"))
        }
    }

    /// Сырые байты ответа (медиа, скачивание).
    public func data(_ method: Method,
                     _ absolutePath: String,
                     query: [String: String] = [:],
                     body: JSONValue? = nil,
                     authenticated: Bool = true,
                     timeout: Duration? = nil) async throws(MatrixError) -> Data {
        var request = try makeRequest(method, absolutePath, query: query, authenticated: authenticated, timeout: timeout)
        if let body {
            do {
                request.httpBody = try body.data()
            } catch {
                throw MatrixError(.decoding("тело запроса: \(error)"))
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(request)
    }

    /// Загрузка байтов (медиа) с заданным Content-Type.
    public func upload(_ absolutePath: String,
                       query: [String: String] = [:],
                       body: Data,
                       contentType: String) async throws(MatrixError) -> Data {
        var request = try makeRequest(.post, absolutePath, query: query, authenticated: true, timeout: .seconds(300))
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return try await perform(request)
    }

    // MARK: Внутреннее

    private func makeRequest(_ method: Method, _ absolutePath: String, query: [String: String],
                             authenticated: Bool, timeout: Duration?) throws(MatrixError) -> URLRequest {
        guard var components = URLComponents(url: homeserver, resolvingAgainstBaseURL: false) else {
            throw MatrixError(.network("плохой адрес сервера"))
        }
        components.percentEncodedPath = Self.encodePath(absolutePath)
        if !query.isEmpty {
            components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        }
        guard let url = components.url else { throw MatrixError(.network("плохой путь \(absolutePath)")) }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let timeout {
            request.timeoutInterval = TimeInterval(timeout.components.seconds) + 5
        }
        if authenticated {
            guard let accessToken else { throw MatrixError(.noAccessToken) }
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Сегменты пути (идентификаторы комнат и событий содержат `!`, `:`, `$`) кодируем по RFC 3986.
    static func encodePath(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    private func perform(_ request: URLRequest) async throws(MatrixError) -> Data {
        var attempt = 0
        var waited: Duration = .zero
        while true {
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError where error.code == .cancelled {
                throw MatrixError(.cancelled)
            } catch {
                throw MatrixError(.network(error.localizedDescription))
            }
            guard let http = response as? HTTPURLResponse else { throw MatrixError(.network("не HTTP-ответ")) }
            if (200..<300).contains(http.statusCode) { return data }

            let error = Self.parseError(status: http.statusCode, data: data, headers: http.allHeaderFields)
            if http.statusCode == 429, attempt < maxRateLimitRetries {
                let pause = error.retryAfter ?? .seconds(2)
                if waited + pause <= maxRetryWait {
                    attempt += 1
                    waited += pause
                    try? await Task.sleep(for: pause)
                    continue
                }
            }
            throw error
        }
    }

    static func parseError(status: Int, data: Data, headers: [AnyHashable: Any]) -> MatrixError {
        var retryAfter: Duration?
        if let header = headers["Retry-After"] as? String, let seconds = Double(header) {
            retryAfter = .seconds(seconds)
        }
        if let json = try? JSONValue(data: data), let errcode = json["errcode"]?.string {
            if let ms = json["retry_after_ms"]?.int { retryAfter = .milliseconds(ms) }
            return MatrixError(.server(status: status, errcode: errcode, message: json["error"]?.string ?? ""),
                               retryAfter: retryAfter)
        }
        return MatrixError(.http(status: status), retryAfter: retryAfter)
    }

    public enum Method: String, Sendable {
        case get = "GET", post = "POST", put = "PUT", delete = "DELETE"
    }
}

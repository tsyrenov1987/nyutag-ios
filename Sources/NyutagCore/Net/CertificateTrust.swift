// Нютаг. Доверие только своему удостоверяющему центру: ядро за кильватером подписано Nyutag Private CA 1,
// системные корни для него не нужны и не используются. Делегат URLSession, годится и для WKWebView-проверок.

import Foundation
import Security

public final class CertificateTrust: NSObject, URLSessionDelegate, Sendable {
    public let anchors: [SecCertificate]
    public let hosts: Set<String>

    /// `hosts` — имена, для которых действует якорь; остальные хосты проверяются по системным корням.
    public init(anchorDER: [Data], hosts: Set<String>) {
        anchors = anchorDER.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        self.hosts = hosts
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        guard hosts.contains(challenge.protectionSpace.host) else {
            return (.performDefaultHandling, nil)
        }
        return evaluate(trust, host: challenge.protectionSpace.host) ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }

    /// Nyutag Private CA 1 (P-256, до 2036-10-08), DER. Публичная часть, секрета нет. Ею подписан сертификат
    /// ядра `core.nyutag.chat:6167`. Если строка не раскодируется, якорей нет и доверия нет (отказ, не обход).
    public static let nyutagCADER = Data(base64Encoded: "MIIBwjCCAWmgAwIBAgIUdESbmTDNd3kdFjE1CO728DfK9mIwCgYIKoZIzj0EAwIwLzEcMBoGA1UEAwwTTnl1dGFnIFByaXZhdGUgQ0EgMTEPMA0GA1UECgwGTnl1dGFnMB4XDTI2MTAxMTAyMTExMFoXDTM2MTAwODAyMTExMFowLzEcMBoGA1UEAwwTTnl1dGFnIFByaXZhdGUgQ0EgMTEPMA0GA1UECgwGTnl1dGFnMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAETor1VmEXfZjHEwb3tN4+7DyeMoYzla+26gWWrryNsukaQWJDKCQIZ9Xss7w9JdT6MgbzeHTOhpp7BS9JUhup9aNjMGEwHQYDVR0OBBYEFD8k/5gpRZdzsql1EE4ibo6gzi+wMB8GA1UdIwQYMBaAFD8k/5gpRZdzsql1EE4ibo6gzi+wMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMCA0cAMEQCIA/jaEWYsLV9gIlj3x3eylQl9rhllpbGYntQlUGl9q3LAiA3lLol4Znkn0ZgIpEIFGu+D+0Mt/kAVjPkv7TN6GASeQ==") ?? Data()

    /// Доверие ядру Нютага: наш CA и имя `core.nyutag.chat`.
    public static func nyutagCore() -> CertificateTrust {
        CertificateTrust(anchorDER: [nyutagCADER], hosts: ["core.nyutag.chat"])
    }

    /// Проверка цепочки против наших якорей с проверкой имени хоста.
    /// `verifyDate` нужен только тестам с зафиксированными сертификатами; в работе `nil` (текущее время).
    public func evaluate(_ trust: SecTrust, host: String, verifyDate: Date? = nil) -> Bool {
        guard !anchors.isEmpty else { return false }
        if let verifyDate, SecTrustSetVerifyDate(trust, verifyDate as CFDate) != errSecSuccess { return false }
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return false }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }
}

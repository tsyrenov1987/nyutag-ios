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

    /// Проверка цепочки против наших якорей с проверкой имени хоста.
    public func evaluate(_ trust: SecTrust, host: String) -> Bool {
        guard !anchors.isEmpty else { return false }
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return false }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }
}

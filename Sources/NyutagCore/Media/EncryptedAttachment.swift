// Нютаг. Зашифрованные вложения для зашифрованных комнат: Matrix spec, «Sending encrypted attachments»
// (EncryptedFile v2). Файл шифруется AES-256-CTR на устройстве, на сервер уходит только шифртекст как
// application/octet-stream, а ключ, iv и SHA-256 шифртекста едут внутри (зашифрованного Megolm) события.

import Foundation
import NyutagCrypto

/// Ключ в формате JWK: `{kty:"oct", key_ops:["encrypt","decrypt"], alg:"A256CTR", k:<base64url без набивки>, ext:true}`.
public struct EncryptedFileKey: Codable, Sendable, Equatable {
    public var kty: String
    public var keyOps: [String]
    public var alg: String
    public var k: String
    public var ext: Bool

    enum CodingKeys: String, CodingKey {
        case kty, alg, k, ext
        case keyOps = "key_ops"
    }

    public init(kty: String = "oct", keyOps: [String] = ["encrypt", "decrypt"], alg: String = "A256CTR",
                k: String, ext: Bool = true) {
        self.kty = kty
        self.keyOps = keyOps
        self.alg = alg
        self.k = k
        self.ext = ext
    }
}

/// Поле `file` (и `info.thumbnail_file`) события m.image / m.file / m.video / m.audio в зашифрованной комнате.
public struct EncryptedFile: Codable, Sendable, Equatable {
    public var url: String
    public var key: EncryptedFileKey
    /// Unpadded base64, 16 байт: 8 случайных + 8 нулевых (нулевая половина — счётчик блоков CTR).
    public var iv: String
    /// `{"sha256": <unpadded base64 от шифртекста>}`.
    public var hashes: [String: String]
    public var v: String

    public init(url: String, key: EncryptedFileKey, iv: String, hashes: [String: String], v: String = "v2") {
        self.url = url
        self.key = key
        self.iv = iv
        self.hashes = hashes
        self.v = v
    }

    /// Шифрование: случайный 32-байтовый ключ, случайные 8 байт iv + 8 нулевых. Возвращает шифртекст и описание
    /// файла; `url` проставляется после загрузки.
    public static func encrypt(_ plaintext: Data, url: String = "") throws(CryptoError) -> (ciphertext: Data, file: EncryptedFile) {
        let key = Random.bytes(32)
        let iv = Random.bytes(8) + Data(count: 8)
        return try encrypt(plaintext, key: key, iv: iv, url: url)
    }

    /// Шифрование с заданными ключом и iv (для тестов и воспроизводимых векторов).
    static func encrypt(_ plaintext: Data, key: Data, iv: Data, url: String) throws(CryptoError) -> (ciphertext: Data, file: EncryptedFile) {
        let ciphertext = try AES.ctr(key: key, iv: iv, input: plaintext)
        let file = EncryptedFile(
            url: url,
            key: EncryptedFileKey(k: Self.base64URL(key)),
            iv: Base64.encodeUnpadded(iv),
            hashes: ["sha256": Base64.encodeUnpadded(Hash.sha256(ciphertext))])
        return (ciphertext, file)
    }

    /// Расшифровка. Сначала сверяется SHA-256 шифртекста (за постоянное время), `v == "v2"` и `alg == "A256CTR"`,
    /// только потом CTR: испорченный файл не расшифровывается вовсе.
    public func decrypt(_ ciphertext: Data) throws(CryptoError) -> Data {
        guard v == "v2" else { throw .badMessage("EncryptedFile: версия \(v), нужна v2") }
        guard key.alg == "A256CTR", key.kty == "oct" else { throw .badMessage("EncryptedFile: алгоритм \(key.alg)") }
        guard let expected = hashes["sha256"] else { throw .badMessage("EncryptedFile: нет hashes.sha256") }
        guard Hash.sha256(ciphertext).constantTimeEquals(try Base64.decode(expected)) else { throw .badMAC }
        let keyBytes = try Self.decodeBase64URL(key.k)
        let ivBytes = try Base64.decode(iv)
        return try AES.ctr(key: keyBytes, iv: ivBytes, input: ciphertext)
    }

    public var mxc: MXC? { MXC(url) }

    /// base64url без набивки (RFC 4648 §5), как требует JWK.
    static func base64URL(_ data: Data) -> String {
        Base64.encodeUnpadded(data).replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    static func decodeBase64URL(_ string: String) throws(CryptoError) -> Data {
        try Base64.decode(string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))
    }

    /// Содержимое m.image / m.file и т. п. для зашифрованной комнаты: `file` вместо `url`, при наличии
    /// `info.thumbnail_file` вместо `thumbnail_url`. `info` — остальные поля (mimetype, size, w, h…).
    public func content(msgtype: String, body: String, info: [String: JSONValue] = [:],
                        thumbnail: EncryptedFile? = nil) throws(MatrixError) -> JSONValue {
        var info = info
        info["thumbnail_url"] = nil
        do {
            if let thumbnail { info["thumbnail_file"] = try Self.json(thumbnail) }
            return .object(["msgtype": .string(msgtype), "body": .string(body),
                            "file": try Self.json(self), "info": .object(info)])
        } catch {
            throw MatrixError(.decoding("EncryptedFile: \(error)"))
        }
    }

    private static func json(_ file: EncryptedFile) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(file))
    }
}

public extension MatrixClient {
    /// Шифрует и грузит файл (на сервере он лежит как application/octet-stream; настоящие имя и тип — в `body`
    /// и `info.mimetype` события, поэтому `contentType` и `filename` на сервер не уходят: они утекли бы открытыми).
    /// Возвращает описание для поля `file`.
    func uploadEncrypted(_ data: Data, contentType _: String, filename _: String? = nil) async throws(MatrixError) -> EncryptedFile {
        let sealed: (ciphertext: Data, file: EncryptedFile)
        do { sealed = try EncryptedFile.encrypt(data) } catch { throw MatrixError(.decoding("шифрование вложения: \(error)")) }
        let mxc = try await uploadMedia(sealed.ciphertext, contentType: "application/octet-stream")
        var file = sealed.file
        file.url = mxc.description
        return file
    }

    /// Скачивает и расшифровывает вложение.
    func downloadDecrypted(_ file: EncryptedFile) async throws -> Data {
        guard let mxc = file.mxc else { throw MatrixError(.decoding("EncryptedFile: плохой url")) }
        return try file.decrypt(try await downloadMedia(mxc))
    }
}

public extension MediaCache {
    /// Расшифрованное вложение. В кэше на диске лежит ШИФРТЕКСТ (тот же ключ `data(_:)`): иначе открытый текст
    /// зашифрованной комнаты осел бы в Caches общей app group, где его видят расширения и бэкапы. Цена —
    /// повторная расшифровка AES-CTR при открытии (аппаратная, быстрая); целостность проверяется каждый раз.
    func decrypted(_ file: EncryptedFile) async throws -> Data {
        guard let mxc = file.mxc else { throw MatrixError(.decoding("EncryptedFile: плохой url")) }
        return try file.decrypt(try await data(mxc))
    }
}

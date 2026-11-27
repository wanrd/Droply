import CryptoKit
import Foundation

public enum SecureChannelError: Error, LocalizedError, Sendable {
    case invalidHandshake(String)
    case invalidKeyMaterial
    case authenticationFailed
    case decryptionFailed
    case sequenceExhausted

    public var errorDescription: String? {
        switch self {
        case .invalidHandshake(let msg):
            return msg
        case .invalidKeyMaterial:
            return "Некорректные криптографические ключи"
        case .authenticationFailed:
            return "Ошибка проверки подлинности соединения"
        case .decryptionFailed:
            return "Ошибка расшифровки или целостности пакета"
        case .sequenceExhausted:
            return "Исчерпан счётчик безопасной сессии"
        }
    }
}

public enum SecureChannel {
    private static let c2sProofContext = Data("droply-v2-c2s-proof".utf8)
    private static let s2cProofContext = Data("droply-v2-s2c-proof".utf8)
    private static let c2sKeyInfo = Data("droply-v2-c2s".utf8)
    private static let s2cKeyInfo = Data("droply-v2-s2c".utf8)

    public static func derivePSK(from token: String) -> SymmetricKey {
        let digest = SHA256.hash(data: Data(token.utf8))
        return SymmetricKey(data: Data(digest))
    }

    public static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for i in bytes.indices {
                bytes[i] = UInt8.random(in: 0...255, using: &rng)
            }
        }
        return Data(bytes)
    }

    public static func computeClientProof(
        psk: SymmetricKey,
        clientPub: Data,
        clientNonce: Data
    ) -> Data {
        var msg = Data()
        msg.append(c2sProofContext)
        msg.append(clientPub)
        msg.append(clientNonce)
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: psk))
    }

    public static func computeServerProof(
        psk: SymmetricKey,
        clientPub: Data,
        serverPub: Data,
        clientNonce: Data,
        serverNonce: Data
    ) -> Data {
        var msg = Data()
        msg.append(s2cProofContext)
        msg.append(clientPub)
        msg.append(serverPub)
        msg.append(clientNonce)
        msg.append(serverNonce)
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: psk))
    }

    /// Constant-time comparison preventing timing side-channels on secrets and HMAC proofs.
    public static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(lhs, rhs) {
            diff |= a ^ b
        }
        return diff == 0
    }

    /// Strips control characters and Unicode bidirectional spoofing overrides from peer strings.
    public static func sanitizeDisplayText(
        _ raw: String,
        maxLength: Int = 64,
        allowNewlines: Bool = false
    ) -> String {
        let normalized = allowNewlines
            ? raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            : raw
        let filtered = normalized.unicodeScalars.filter { scalar in
            if allowNewlines && scalar.value == 0x0A { return true }
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
            if (0x202A...0x202E).contains(scalar.value) { return false }
            if (0x2066...0x2069).contains(scalar.value) { return false }
            if scalar.value == 0x200E || scalar.value == 0x200F { return false }
            return true
        }
        var clean = String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if allowNewlines {
            while clean.contains("\n\n\n") {
                clean = clean.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            }
        }
        if clean.count <= maxLength {
            return clean
        }
        return String(clean.prefix(maxLength))
    }

    public enum Role: Sendable {
        case client
        case server
    }

    /// Per-session directional AES-256-GCM cipher with strictly monotonic 96-bit nonces.
    public final class SessionCipher: @unchecked Sendable {
        private let txLock = NSLock()
        private let rxLock = NSLock()

        private let txKey: SymmetricKey
        private let rxKey: SymmetricKey
        private let txDirection: UInt8
        private let rxDirection: UInt8
        private var txSequence: UInt64 = 0
        private var rxSequence: UInt64 = 0

        public init(
            sharedSecret: SharedSecret,
            psk: SymmetricKey,
            clientNonce: Data,
            serverNonce: Data,
            role: Role
        ) {
            let sharedData = sharedSecret.withUnsafeBytes { Data($0) }
            let pskData = psk.withUnsafeBytes { Data($0) }
            var ikmData = Data(capacity: sharedData.count + pskData.count)
            ikmData.append(sharedData)
            ikmData.append(pskData)

            var salt = Data(capacity: clientNonce.count + serverNonce.count)
            salt.append(clientNonce)
            salt.append(serverNonce)

            let ikm = SymmetricKey(data: ikmData)
            let c2sKey = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: ikm,
                salt: salt,
                info: c2sKeyInfo,
                outputByteCount: 32
            )
            let s2cKey = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: ikm,
                salt: salt,
                info: s2cKeyInfo,
                outputByteCount: 32
            )

            switch role {
            case .client:
                self.txKey = c2sKey
                self.rxKey = s2cKey
                self.txDirection = 0x01
                self.rxDirection = 0x02
            case .server:
                self.txKey = s2cKey
                self.rxKey = c2sKey
                self.txDirection = 0x02
                self.rxDirection = 0x01
            }
        }

        public func sealPacket(type: FrameType, plaintext: Data) throws -> Data {
            txLock.lock()
            defer { txLock.unlock() }

            guard txSequence < UInt64.max else {
                throw SecureChannelError.sequenceExhausted
            }
            txSequence += 1
            let seq = txSequence

            let sealedLength = plaintext.count + 16
            guard sealedLength <= Int(DroplyProtocol.maxWireFramePayloadBytes) else {
                throw FrameCodecError.payloadTooLarge(UInt32(sealedLength))
            }

            let nonce = try makeNonce(direction: txDirection, sequence: seq)
            let aad = makeHeader(type: type, payloadLength: UInt32(sealedLength))
            let sealed = try AES.GCM.seal(plaintext, using: txKey, nonce: nonce, authenticating: aad)

            var packet = Data(capacity: 5 + sealedLength)
            packet.append(aad)
            packet.append(sealed.ciphertext)
            packet.append(sealed.tag)
            return packet
        }

        public func openPayload(type: FrameType, sealedPayload: Data) throws -> Data {
            guard sealedPayload.count >= 16 else {
                throw SecureChannelError.decryptionFailed
            }

            rxLock.lock()
            defer { rxLock.unlock() }

            guard rxSequence < UInt64.max else {
                throw SecureChannelError.sequenceExhausted
            }
            rxSequence += 1
            let seq = rxSequence

            let nonce = try makeNonce(direction: rxDirection, sequence: seq)
            let aad = makeHeader(type: type, payloadLength: UInt32(sealedPayload.count))
            let ciphertext = sealedPayload.dropLast(16)
            let tag = sealedPayload.suffix(16)

            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            do {
                return try AES.GCM.open(box, using: rxKey, authenticating: aad)
            } catch {
                throw SecureChannelError.decryptionFailed
            }
        }

        private func makeNonce(direction: UInt8, sequence: UInt64) throws -> AES.GCM.Nonce {
            var bytes = Data(count: 12)
            bytes[0] = direction
            var bigSeq = sequence.bigEndian
            withUnsafeBytes(of: &bigSeq) { bytes.replaceSubrange(4..<12, with: $0) }
            return try AES.GCM.Nonce(data: bytes)
        }

        private func makeHeader(type: FrameType, payloadLength: UInt32) -> Data {
            var header = Data(capacity: 5)
            header.append(type.rawValue)
            var bigLen = payloadLength.bigEndian
            withUnsafeBytes(of: &bigLen) { header.append(contentsOf: $0) }
            return header
        }
    }
}

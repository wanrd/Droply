import Foundation

public enum DroplyProtocol {
    public static let version: Int = 1
    public static let defaultPort: UInt16 = 45820
    public static let chunkSize: Int = 256 * 1024 // 256 KB chunks for high-throughput streaming
    public static let maxFramePayloadBytes: UInt32 = 16 * 1024 * 1024 // 16 MB plaintext limit per frame
    public static let maxWireFramePayloadBytes: UInt32 = maxFramePayloadBytes + 16 // +16 bytes AES-GCM tag
    public static let maxControlFrameBytes: UInt32 = 128 * 1024 // 128 KB JSON control limit
}

public enum FrameType: UInt8, Sendable {
    case hello = 0x01
    case helloAck = 0x02
    case batchStart = 0x03
    case fileStart = 0x04
    case fileChunk = 0x05
    case fileEnd = 0x06
    case progressAck = 0x07
    case fileResult = 0x08
    case batchEnd = 0x09
    case cancel = 0x0A
    case disconnect = 0x0B
    case ping = 0x0C
    case pong = 0x0D
    case batchAccept = 0x0E
    case authIdentity = 0x0F
    case authResult = 0x10
}

public struct QRPairingPayload: Codable, Sendable, Equatable {
    public let v: Int
    public let host: String
    public let hosts: [String]?
    public let port: UInt16
    public let token: String
    public let name: String

    public init(
        v: Int = DroplyProtocol.version,
        host: String,
        hosts: [String]? = nil,
        port: UInt16,
        token: String,
        name: String
    ) {
        self.v = v
        self.host = host
        self.hosts = hosts
        self.port = port
        self.token = token
        self.name = name
    }

    public func toJSONString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let str = String(data: data, encoding: .utf8) else {
            throw FrameCodecError.invalidUTF8
        }
        return str
    }
}

public struct HelloPayload: Codable, Sendable {
    public let clientPub: String
    public let clientNonce: String
    public let clientProof: String

    public init(clientPub: String, clientNonce: String, clientProof: String) {
        self.clientPub = clientPub
        self.clientNonce = clientNonce
        self.clientProof = clientProof
    }
}

public struct HelloAckPayload: Codable, Sendable {
    public let ok: Bool
    public let serverPub: String?
    public let serverNonce: String?
    public let serverProof: String?
    public let error: String?

    public init(
        ok: Bool,
        serverPub: String? = nil,
        serverNonce: String? = nil,
        serverProof: String? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        self.serverPub = serverPub
        self.serverNonce = serverNonce
        self.serverProof = serverProof
        self.error = error
    }
}

public struct AuthIdentityPayload: Codable, Sendable {
    public let deviceName: String

    public init(deviceName: String) {
        self.deviceName = deviceName
    }
}

public struct AuthResultPayload: Codable, Sendable {
    public let ok: Bool
    public let deviceName: String
    public let error: String?

    public init(ok: Bool, deviceName: String, error: String? = nil) {
        self.ok = ok
        self.deviceName = deviceName
        self.error = error
    }
}

public struct BatchStartPayload: Codable, Sendable {
    public let batchId: String
    public let totalFiles: Int
    public let totalBytes: UInt64
    public let previewName: String?

    public init(batchId: String, totalFiles: Int, totalBytes: UInt64, previewName: String? = nil) {
        self.batchId = batchId
        self.totalFiles = totalFiles
        self.totalBytes = totalBytes
        self.previewName = previewName
    }
}

public struct BatchAcceptPayload: Codable, Sendable {
    public let batchId: String
    public let accepted: Bool
    public let reason: String?

    public init(batchId: String, accepted: Bool, reason: String? = nil) {
        self.batchId = batchId
        self.accepted = accepted
        self.reason = reason
    }
}

public struct FileStartPayload: Codable, Sendable {
    public let fileIndex: Int
    public let relativePath: String
    public let size: UInt64
    public let isText: Bool

    public init(fileIndex: Int, relativePath: String, size: UInt64, isText: Bool = false) {
        self.fileIndex = fileIndex
        self.relativePath = relativePath
        self.size = size
        self.isText = isText
    }
}

public struct FileEndPayload: Codable, Sendable {
    public let sha256: String

    public init(sha256: String) {
        self.sha256 = sha256
    }
}

public struct ProgressAckPayload: Codable, Sendable {
    public let fileIndex: Int
    public let fileBytesReceived: UInt64
    public let batchBytesReceived: UInt64
    public let totalBytes: UInt64
    public let percent: Double

    public init(fileIndex: Int, fileBytesReceived: UInt64, batchBytesReceived: UInt64, totalBytes: UInt64, percent: Double) {
        self.fileIndex = fileIndex
        self.fileBytesReceived = fileBytesReceived
        self.batchBytesReceived = batchBytesReceived
        self.totalBytes = totalBytes
        self.percent = percent
    }
}

public struct FileResultPayload: Codable, Sendable {
    public let fileIndex: Int
    public let ok: Bool
    public let savedPath: String?
    public let error: String?

    public init(fileIndex: Int, ok: Bool, savedPath: String? = nil, error: String? = nil) {
        self.fileIndex = fileIndex
        self.ok = ok
        self.savedPath = savedPath
        self.error = error
    }
}

public struct BatchEndPayload: Codable, Sendable {
    public let batchId: String

    public init(batchId: String) {
        self.batchId = batchId
    }
}

public struct CancelPayload: Codable, Sendable {
    public let reason: String
    public let target: String?

    public init(reason: String, target: String? = nil) {
        self.reason = reason
        self.target = target
    }
}

public enum FrameCodecError: Error, LocalizedError, Sendable {
    case invalidFrameType(UInt8)
    case payloadTooLarge(UInt32)
    case unexpectedEOF
    case invalidUTF8
    case socketError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFrameType(let raw):
            return "Неизвестный тип пакета: \(raw)"
        case .payloadTooLarge(let size):
            return "Размер пакета слишком велик: \(size) байт"
        case .unexpectedEOF:
            return "Соединение закрыто удалённой стороной"
        case .invalidUTF8:
            return "Ошибка кодировки UTF-8"
        case .socketError(let message):
            return "Сетевая ошибка: \(message)"
        }
    }
}

public struct RawFrame: Sendable {
    public let type: FrameType
    public let payload: Data

    public init(type: FrameType, payload: Data) {
        self.type = type
        self.payload = payload
    }
}

public enum FrameCodec {
    public static func encodeFrame(type: FrameType, payload: Data = Data()) throws -> Data {
        guard payload.count <= Int(DroplyProtocol.maxFramePayloadBytes) else {
            throw FrameCodecError.payloadTooLarge(UInt32(payload.count))
        }
        var packet = Data(capacity: 5 + payload.count)
        packet.append(type.rawValue)
        var bigEndianLen = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &bigEndianLen) { packet.append(contentsOf: $0) }
        packet.append(payload)
        return packet
    }

    public static func encodeJSON<T: Encodable>(type: FrameType, value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        return try encodeFrame(type: type, payload: data)
    }

    public static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }
}

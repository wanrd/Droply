import CryptoKit
import Darwin
import Foundation

public struct TransferProgressSnapshot: Sendable, Equatable {
    public let fileIndex: Int
    public let totalFiles: Int
    public let currentFileName: String
    public let fileBytesReceived: UInt64
    public let fileTotalBytes: UInt64
    public let batchBytesReceived: UInt64
    public let batchTotalBytes: UInt64
    public let percent: Double
    public let speedBytesPerSecond: Double
    public let isIncoming: Bool

    public init(
        fileIndex: Int,
        totalFiles: Int,
        currentFileName: String,
        fileBytesReceived: UInt64,
        fileTotalBytes: UInt64,
        batchBytesReceived: UInt64,
        batchTotalBytes: UInt64,
        percent: Double,
        speedBytesPerSecond: Double,
        isIncoming: Bool = true
    ) {
        self.fileIndex = fileIndex
        self.totalFiles = totalFiles
        self.currentFileName = currentFileName
        self.fileBytesReceived = fileBytesReceived
        self.fileTotalBytes = fileTotalBytes
        self.batchBytesReceived = batchBytesReceived
        self.batchTotalBytes = batchTotalBytes
        self.percent = percent
        self.speedBytesPerSecond = speedBytesPerSecond
        self.isIncoming = isIncoming
    }
}

public struct ReceivedFileRecord: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public let fileName: String
    public let relativePath: String
    public let savedURL: URL
    public let size: UInt64
    public let isText: Bool
    public let isIncoming: Bool
    public let sha256: String
    public let textContent: String?
    public let receivedAt: Date

    public init(
        id: UUID = UUID(),
        fileName: String,
        relativePath: String,
        savedURL: URL,
        size: UInt64,
        isText: Bool,
        isIncoming: Bool = true,
        sha256: String,
        textContent: String? = nil,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.relativePath = relativePath
        self.savedURL = savedURL
        self.size = size
        self.isText = isText
        self.isIncoming = isIncoming
        self.sha256 = sha256
        self.textContent = textContent
        self.receivedAt = receivedAt
    }
}

public struct IncomingBatchRequest: Sendable, Equatable, Identifiable {
    public var id: String { batchId }
    public let batchId: String
    public let senderName: String
    public let totalFiles: Int
    public let totalBytes: UInt64
    public let previewName: String?

    public init(batchId: String, senderName: String, totalFiles: Int, totalBytes: UInt64, previewName: String?) {
        self.batchId = batchId
        self.senderName = senderName
        self.totalFiles = totalFiles
        self.totalBytes = totalBytes
        self.previewName = previewName
    }
}

public struct IncomingPairingRequest: Sendable, Equatable, Identifiable {
    public var id: String { requestId }
    public let requestId: String
    public let deviceName: String
    public let remoteIP: String

    public init(requestId: String, deviceName: String, remoteIP: String) {
        self.requestId = requestId
        self.deviceName = deviceName
        self.remoteIP = remoteIP
    }
}

public enum ServerEvent: Sendable {
    case started(host: String, port: UInt16, token: String)
    case stopped
    case incomingPairingRequest(IncomingPairingRequest)
    case incomingPairingCancelled(requestId: String)
    case peerConnected(deviceName: String, remoteIP: String)
    case peerDisconnected(reason: String?)
    case incomingBatchRequest(IncomingBatchRequest)
    case awaitingPeerConfirmation(deviceName: String, totalFiles: Int, totalBytes: UInt64)
    case batchStarted(batchId: String, totalFiles: Int, totalBytes: UInt64, isIncoming: Bool)
    case fileStarted(fileIndex: Int, totalFiles: Int, relativePath: String, fileSize: UInt64, isText: Bool)
    case progress(TransferProgressSnapshot)
    case fileCompleted(ReceivedFileRecord)
    case batchCompleted(batchId: String, fileCount: Int, isIncoming: Bool)
    case transferCancelled(reason: String)
    case error(String)
}

private final class SocketStream: @unchecked Sendable {
    let fd: Int32
    let sessionID = UUID()
    private let sendLock = NSLock()
    private let closeLock = NSLock()
    private let cipherLock = NSLock()
    private var cipher: SecureChannel.SessionCipher?
    private var isClosed = false

    init(fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        var keepIdle: Int32 = 10
        var keepInterval: Int32 = 3
        var keepCount: Int32 = 4
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &keepIdle, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &keepInterval, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &keepCount, socklen_t(MemoryLayout<Int32>.size))
        setReceiveTimeout(seconds: 5)
    }

    func setReceiveTimeout(seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func enableCipher(_ sessionCipher: SecureChannel.SessionCipher) {
        cipherLock.lock()
        cipher = sessionCipher
        cipherLock.unlock()
    }

    private func activeCipher() -> SecureChannel.SessionCipher? {
        cipherLock.lock()
        defer { cipherLock.unlock() }
        return cipher
    }

    func readExact(count: Int) throws -> Data {
        if count == 0 { return Data() }
        var data = Data(count: count)
        var totalRead = 0
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while totalRead < count {
                let n = Darwin.recv(fd, base.advanced(by: totalRead), count - totalRead, 0)
                if n > 0 {
                    totalRead += n
                } else if n == 0 {
                    throw FrameCodecError.unexpectedEOF
                } else {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK ||
                        errno == ECONNRESET || errno == EBADF || errno == ENOTCONN || errno == ETIMEDOUT {
                        throw FrameCodecError.unexpectedEOF
                    }
                    throw FrameCodecError.socketError(String(cString: strerror(errno)))
                }
            }
        }
        return data
    }

    func readFrame() throws -> RawFrame {
        let header = try readExact(count: 5)
        let typeByte = header[0]
        guard let frameType = FrameType(rawValue: typeByte) else {
            throw FrameCodecError.invalidFrameType(typeByte)
        }
        let len: UInt32 = header.withUnsafeBytes { ptr in
            let raw = ptr.loadUnaligned(fromByteOffset: 1, as: UInt32.self)
            return UInt32(bigEndian: raw)
        }
        let currentCipher = activeCipher()
        let maxLen: UInt32 = if frameType == .fileChunk {
            currentCipher != nil ? DroplyProtocol.maxWireFramePayloadBytes : DroplyProtocol.maxFramePayloadBytes
        } else {
            currentCipher != nil ? (DroplyProtocol.maxControlFrameBytes + 16) : DroplyProtocol.maxControlFrameBytes
        }
        guard len <= maxLen else {
            throw FrameCodecError.payloadTooLarge(len)
        }
        let payload = try readExact(count: Int(len))
        if let currentCipher {
            let decrypted = try currentCipher.openPayload(type: frameType, sealedPayload: payload)
            return RawFrame(type: frameType, payload: decrypted)
        }
        return RawFrame(type: frameType, payload: payload)
    }

    private func sendAllLocked(_ data: Data) throws {
        closeLock.lock()
        let alreadyClosed = isClosed
        closeLock.unlock()
        if alreadyClosed {
            throw FrameCodecError.unexpectedEOF
        }

        var totalSent = 0
        let count = data.count
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while totalSent < count {
                let n = Darwin.send(fd, base.advanced(by: totalSent), count - totalSent, 0)
                if n > 0 {
                    totalSent += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    throw FrameCodecError.socketError(String(cString: strerror(errno)))
                }
            }
        }
    }

    func sendAll(_ data: Data) throws {
        sendLock.lock()
        defer { sendLock.unlock() }
        try sendAllLocked(data)
    }

    func sendFrame(type: FrameType, payload: Data) throws {
        sendLock.lock()
        defer { sendLock.unlock() }

        if let currentCipher = activeCipher() {
            let packet = try currentCipher.sealPacket(type: type, plaintext: payload)
            try sendAllLocked(packet)
        } else {
            let packet = try FrameCodec.encodeFrame(type: type, payload: payload)
            try sendAllLocked(packet)
        }
    }

    func sendJSON<T: Encodable>(type: FrameType, value: T) throws {
        let data = try JSONEncoder().encode(value)
        try sendFrame(type: type, payload: data)
    }

    func closeSocket() {
        closeLock.lock()
        if isClosed {
            closeLock.unlock()
            return
        }
        isClosed = true
        closeLock.unlock()

        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

private final class IncomingBatchSession {
    let batch: BatchStartPayload
    let baseDir: URL
    let overwrite: Bool
    var approved: Bool?
    var cancelled = false
    let batchStartTime = Date()
    var batchBytesReceived: UInt64 = 0
    var completedFilesCount = 0
    var lastAckTime = Date.distantPast
    var lastAckBytes: UInt64 = 0

    var currentFileStart: FileStartPayload?
    var currentTempURL: URL?
    var currentFinalURL: URL?
    var currentHandle: FileHandle?
    var currentHasher = SHA256()
    var currentFileBytes: UInt64 = 0

    init(batch: BatchStartPayload, baseDir: URL, overwrite: Bool, approved: Bool?) {
        self.batch = batch
        self.baseDir = baseDir
        self.overwrite = overwrite
        self.approved = approved
    }

    func cleanupActiveTempFile() {
        try? currentHandle?.close()
        currentHandle = nil
        if let temp = currentTempURL {
            try? FileManager.default.removeItem(at: temp)
        }
        currentTempURL = nil
        currentFinalURL = nil
        currentFileStart = nil
    }
}

private final class OutgoingWaiter<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: T?
    private var completed = false

    func resolve(_ value: T) {
        lock.lock()
        let shouldSignal = !completed
        if shouldSignal {
            result = value
            completed = true
        }
        lock.unlock()
        if shouldSignal {
            semaphore.signal()
        }
    }

    func wait() -> T? {
        semaphore.wait()
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func wait(timeoutSeconds: TimeInterval) -> T? {
        let res = semaphore.wait(timeout: .now() + timeoutSeconds)
        lock.lock()
        defer { lock.unlock() }
        return res == .success ? result : nil
    }
}

public final class DroplyServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var activeClient: SocketStream?
    private var activeSessionID: UUID?
    private var activePeerName: String = "Android"
    private var isRunningFlag = false
    private var token: String = NetworkUtils.generateSessionToken()
    private var listeningPort: UInt16 = DroplyProtocol.defaultPort
    private var destinationDirectory: URL
    private var overwriteExisting: Bool
    private var requireIncomingConfirmation: Bool
    private var requirePairingConfirmation: Bool
    private var deviceName: String

    // Pending pairing confirmations
    private var pendingPairingWaiters: [String: OutgoingWaiter<Bool>] = [:]

    // DoS / brute-force protection
    private struct AuthAttemptRecord {
        var count: Int
        var windowStart: Date
        var blockedUntil: Date?
    }
    private var authAttemptsByIP: [String: AuthAttemptRecord] = [:]
    private var unauthenticatedConnections = 0
    private static let maxUnauthenticatedConnections = 8
    private static let maxFailedAuthAttempts = 5
    private static let authWindowSeconds: TimeInterval = 60
    private static let authBlockSeconds: TimeInterval = 60
    private static let maxBatchFiles = 50_000
    private static let maxBatchBytes: UInt64 = 100_000_000_000
    private static let diskFreeMarginBytes: UInt64 = 256 * 1024 * 1024

    // Incoming transfer state
    private var incomingSession: IncomingBatchSession?

    // Outgoing transfer state
    private var isOutgoingActiveFlag = false
    private var outgoingCancelRequested = false
    private var outgoingBatchId: String?
    private var outgoingStartMs = Date()
    private var outgoingTotalFiles = 0
    private var outgoingTotalBytes: UInt64 = 0
    private var outgoingCurrentFileName = ""
    private var outgoingConfirmedBytes: UInt64 = 0
    private var outgoingConfirmedPercent: Double = 0
    private var batchAcceptWaiter: OutgoingWaiter<BatchAcceptPayload>?
    private var fileResultWaiters: [Int: OutgoingWaiter<FileResultPayload>] = [:]

    private let onEvent: @Sendable (ServerEvent) -> Void

    public init(
        destinationDirectory: URL,
        overwriteExisting: Bool = false,
        requireIncomingConfirmation: Bool = true,
        requirePairingConfirmation: Bool = false,
        deviceName: String = Host.current().localizedName ?? "MacBook",
        onEvent: @escaping @Sendable (ServerEvent) -> Void
    ) {
        self.destinationDirectory = destinationDirectory
        self.overwriteExisting = overwriteExisting
        self.requireIncomingConfirmation = requireIncomingConfirmation
        self.requirePairingConfirmation = requirePairingConfirmation
        self.deviceName = deviceName
        self.onEvent = onEvent
    }

    public var currentDestinationDirectory: URL {
        lock.lock()
        defer { lock.unlock() }
        return destinationDirectory
    }

    public func updateDestinationDirectory(_ url: URL) {
        lock.lock()
        destinationDirectory = url
        lock.unlock()
    }

    public func updateOverwriteExisting(_ overwrite: Bool) {
        lock.lock()
        overwriteExisting = overwrite
        lock.unlock()
    }

    public func updateRequireIncomingConfirmation(_ require: Bool) {
        lock.lock()
        requireIncomingConfirmation = require
        lock.unlock()
    }

    public func updateDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        deviceName = trimmed
        lock.unlock()
    }

    public var currentDeviceName: String {
        lock.lock()
        defer { lock.unlock() }
        return deviceName
    }

    public var currentToken: String {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    public var currentPort: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return listeningPort
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunningFlag
    }

    public func start(port: UInt16 = DroplyProtocol.defaultPort) throws {
        stop()

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw FrameCodecError.socketError(String(cString: strerror(errno)))
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = String(cString: strerror(errno))
            Darwin.close(fd)
            throw FrameCodecError.socketError("Не удалось открыть порт \(port): \(err)")
        }

        guard Darwin.listen(fd, 8) == 0 else {
            let err = String(cString: strerror(errno))
            Darwin.close(fd)
            throw FrameCodecError.socketError("Ошибка listen: \(err)")
        }

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let sockNameRes = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.getsockname(fd, saPtr, &boundLen)
            }
        }
        let actualPort = sockNameRes == 0 ? UInt16(bigEndian: boundAddr.sin_port) : port
        let newToken = NetworkUtils.generateSessionToken()

        lock.lock()
        listenFD = fd
        listeningPort = actualPort
        token = newToken
        isRunningFlag = true
        lock.unlock()

        let host = NetworkUtils.primaryWiFiIPv4()
        onEvent(.started(host: host, port: actualPort, token: newToken))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop(listenFD: fd)
        }
    }

    public func respondToPairingRequest(requestId: String, accepted: Bool) {
        lock.lock()
        let waiter = pendingPairingWaiters.removeValue(forKey: requestId)
        lock.unlock()
        waiter?.resolve(accepted)
    }

    public func respondToIncomingBatch(batchId: String, accepted: Bool) {
        lock.lock()
        let client = activeClient
        let session = incomingSession
        guard let session, session.batch.batchId == batchId, session.approved == nil else {
            lock.unlock()
            return
        }
        session.approved = accepted
        if !accepted {
            session.cancelled = true
            session.cleanupActiveTempFile()
        }
        lock.unlock()

        if let client {
            let reason = accepted ? nil : "Получение отклонено на MacBook"
            try? client.sendJSON(
                type: .batchAccept,
                value: BatchAcceptPayload(batchId: batchId, accepted: accepted, reason: reason)
            )
        }

        if accepted {
            onEvent(.batchStarted(
                batchId: session.batch.batchId,
                totalFiles: session.batch.totalFiles,
                totalBytes: session.batch.totalBytes,
                isIncoming: true
            ))
        } else {
            lock.lock()
            if incomingSession?.batch.batchId == batchId {
                incomingSession = nil
            }
            lock.unlock()
            onEvent(.transferCancelled(reason: "Получение отклонено на MacBook"))
        }
    }

    public func sendItems(_ items: [MacSendItem]) {
        guard !items.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performSendItems(items)
        }
    }

    private func performSendItems(_ items: [MacSendItem]) {
        lock.lock()
        guard let stream = activeClient, let sessionID = activeSessionID else {
            lock.unlock()
            onEvent(.error("Нет подключённого Android-устройства"))
            return
        }
        guard !isOutgoingActiveFlag else {
            lock.unlock()
            onEvent(.error("Дождитесь завершения текущей отправки"))
            return
        }

        let batchId = UUID().uuidString
        let totalBytes = items.reduce(UInt64(0)) { $0 &+ $1.sizeBytes }
        let peerName = activePeerName

        isOutgoingActiveFlag = true
        outgoingCancelRequested = false
        outgoingBatchId = batchId
        outgoingStartMs = Date()
        outgoingTotalFiles = items.count
        outgoingTotalBytes = totalBytes
        outgoingCurrentFileName = URL(fileURLWithPath: items[0].relativePath).lastPathComponent
        outgoingConfirmedBytes = 0
        outgoingConfirmedPercent = 0
        let acceptWaiter = OutgoingWaiter<BatchAcceptPayload>()
        batchAcceptWaiter = acceptWaiter
        fileResultWaiters.removeAll()
        lock.unlock()

        defer {
            lock.lock()
            if activeSessionID == sessionID {
                isOutgoingActiveFlag = false
                outgoingCancelRequested = false
                outgoingBatchId = nil
                batchAcceptWaiter = nil
                fileResultWaiters.removeAll()
            }
            lock.unlock()
        }

        do {
            onEvent(.awaitingPeerConfirmation(deviceName: peerName, totalFiles: items.count, totalBytes: totalBytes))

            let preview = items.count == 1 ? items[0].relativePath : nil
            try stream.sendJSON(
                type: .batchStart,
                value: BatchStartPayload(
                    batchId: batchId,
                    totalFiles: items.count,
                    totalBytes: totalBytes,
                    previewName: preview
                )
            )

            guard let acceptResponse = acceptWaiter.wait() else {
                onEvent(.transferCancelled(reason: "Передача прервана"))
                return
            }

            if !acceptResponse.accepted {
                onEvent(.transferCancelled(reason: acceptResponse.reason ?? "Смартфон отклонил получение"))
                return
            }

            onEvent(.batchStarted(batchId: batchId, totalFiles: items.count, totalBytes: totalBytes, isIncoming: false))

            var sentBatchBytes: UInt64 = 0
            var completedCount = 0
            var lastUiUpdate = Date.distantPast

            for (index, item) in items.enumerated() {
                lock.lock()
                let cancelled = outgoingCancelRequested
                outgoingCurrentFileName = URL(fileURLWithPath: item.relativePath).lastPathComponent
                let resultWaiter = OutgoingWaiter<FileResultPayload>()
                fileResultWaiters[index] = resultWaiter
                lock.unlock()

                if cancelled { break }

                onEvent(.fileStarted(
                    fileIndex: index,
                    totalFiles: items.count,
                    relativePath: item.relativePath,
                    fileSize: item.sizeBytes,
                    isText: item.isText
                ))

                try stream.sendJSON(
                    type: .fileStart,
                    value: FileStartPayload(
                        fileIndex: index,
                        relativePath: item.relativePath,
                        size: item.sizeBytes,
                        isText: item.isText
                    )
                )

                var hasher = SHA256()
                switch item {
                case .textNote(_, let data):
                    var offset = 0
                    while offset < data.count {
                        lock.lock()
                        let isCancelled = outgoingCancelRequested
                        lock.unlock()
                        if isCancelled { break }

                        let end = min(offset + DroplyProtocol.chunkSize, data.count)
                        let chunk = data.subdata(in: offset..<end)
                        hasher.update(data: chunk)
                        try stream.sendFrame(type: .fileChunk, payload: chunk)
                        sentBatchBytes &+= UInt64(chunk.count)
                        offset = end
                        emitLocalSendProgressIfNeeded(
                            fileIndex: index,
                            totalFiles: items.count,
                            fileName: URL(fileURLWithPath: item.relativePath).lastPathComponent,
                            sentBatchBytes: sentBatchBytes,
                            totalBytes: totalBytes,
                            lastUpdate: &lastUiUpdate
                        )
                    }

                case .file(let url, _, _, _):
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    while true {
                        lock.lock()
                        let isCancelled = outgoingCancelRequested
                        lock.unlock()
                        if isCancelled { break }

                        let chunk = try handle.read(upToCount: DroplyProtocol.chunkSize) ?? Data()
                        if chunk.isEmpty { break }
                        hasher.update(data: chunk)
                        try stream.sendFrame(type: .fileChunk, payload: chunk)
                        sentBatchBytes &+= UInt64(chunk.count)
                        emitLocalSendProgressIfNeeded(
                            fileIndex: index,
                            totalFiles: items.count,
                            fileName: URL(fileURLWithPath: item.relativePath).lastPathComponent,
                            sentBatchBytes: sentBatchBytes,
                            totalBytes: totalBytes,
                            lastUpdate: &lastUiUpdate
                        )
                    }
                }

                lock.lock()
                let cancelledDuringSend = outgoingCancelRequested
                lock.unlock()
                if cancelledDuringSend { break }

                let shaHex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                try stream.sendJSON(type: .fileEnd, value: FileEndPayload(sha256: shaHex))

                guard let fileResult = resultWaiter.wait() else {
                    break
                }

                if fileResult.ok {
                    completedCount += 1
                    let savedURL: URL
                    let noteText: String?
                    switch item {
                    case .file(let url, _, _, _):
                        savedURL = url
                        noteText = nil
                    case .textNote(_, let data):
                        savedURL = destinationDirectory.appendingPathComponent(item.relativePath)
                        noteText = data.count <= 1_048_576 ? String(data: data, encoding: .utf8) : nil
                    }
                    onEvent(.fileCompleted(ReceivedFileRecord(
                        fileName: URL(fileURLWithPath: item.relativePath).lastPathComponent,
                        relativePath: item.relativePath,
                        savedURL: savedURL,
                        size: item.sizeBytes,
                        isText: item.isText,
                        isIncoming: false,
                        sha256: shaHex,
                        textContent: noteText
                    )))
                } else {
                    onEvent(.error(fileResult.error ?? "Ошибка отправки \(item.relativePath)"))
                }
            }

            lock.lock()
            let cancelledAtEnd = outgoingCancelRequested
            lock.unlock()

            if cancelledAtEnd {
                try? stream.sendJSON(
                    type: .cancel,
                    value: CancelPayload(reason: "Передача отменена", target: "incoming")
                )
                onEvent(.transferCancelled(reason: "Передача отменена"))
            } else {
                try stream.sendJSON(type: .batchEnd, value: BatchEndPayload(batchId: batchId))
                onEvent(.batchCompleted(batchId: batchId, fileCount: completedCount, isIncoming: false))
            }
        } catch {
            lock.lock()
            let wasCancelled = outgoingCancelRequested
            lock.unlock()
            if !wasCancelled {
                try? stream.sendJSON(
                    type: .cancel,
                    value: CancelPayload(reason: error.localizedDescription, target: "incoming")
                )
                onEvent(.error(error.localizedDescription))
            }
        }
    }

    private func emitLocalSendProgressIfNeeded(
        fileIndex: Int,
        totalFiles: Int,
        fileName: String,
        sentBatchBytes: UInt64,
        totalBytes: UInt64,
        lastUpdate: inout Date
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= 0.08 else { return }
        lastUpdate = now

        lock.lock()
        let confirmedPct = outgoingConfirmedPercent
        let confirmedBytes = outgoingConfirmedBytes
        let start = outgoingStartMs
        lock.unlock()

        guard confirmedPct == 0 else { return }
        let elapsed = max(now.timeIntervalSince(start), 0.001)
        let pct = totalBytes == 0 ? 0.0 : min(99.9, Double(sentBatchBytes) * 100.0 / Double(totalBytes))
        onEvent(.progress(TransferProgressSnapshot(
            fileIndex: fileIndex,
            totalFiles: totalFiles,
            currentFileName: fileName,
            fileBytesReceived: 0,
            fileTotalBytes: totalBytes,
            batchBytesReceived: max(confirmedBytes, sentBatchBytes),
            batchTotalBytes: totalBytes,
            percent: pct,
            speedBytesPerSecond: Double(sentBatchBytes) / elapsed,
            isIncoming: false
        )))
    }

    public func regenerateTokenAndDisconnectPeer() {
        let newToken = NetworkUtils.generateSessionToken()
        lock.lock()
        token = newToken
        let client = activeClient
        let hadClient = activeSessionID != nil
        activeClient = nil
        activeSessionID = nil
        incomingSession?.cancelled = true
        incomingSession?.cleanupActiveTempFile()
        incomingSession = nil
        outgoingCancelRequested = true
        let acceptW = batchAcceptWaiter
        let resultWaiters = Array(fileResultWaiters.values)
        let pairingWs = Array(pendingPairingWaiters.values)
        batchAcceptWaiter = nil
        fileResultWaiters.removeAll()
        pendingPairingWaiters.removeAll()
        let port = listeningPort
        let running = isRunningFlag
        lock.unlock()

        pairingWs.forEach { $0.resolve(false) }
        acceptW?.resolve(BatchAcceptPayload(batchId: "", accepted: false, reason: "Сессия сброшена"))
        resultWaiters.forEach { $0.resolve(FileResultPayload(fileIndex: -1, ok: false, error: "Сессия сброшена")) }

        if let client {
            try? client.sendJSON(type: .disconnect, value: [String: String]())
            client.closeSocket()
        }
        if hadClient {
            onEvent(.peerDisconnected(reason: "Сессия сброшена пользователем"))
        }
        if running {
            onEvent(.started(host: NetworkUtils.primaryWiFiIPv4(), port: port, token: newToken))
        }
    }

    public func disconnectCurrentPeer(reason: String = "Отключено пользователем") {
        lock.lock()
        let client = activeClient
        let hadClient = activeSessionID != nil
        activeClient = nil
        activeSessionID = nil
        incomingSession?.cancelled = true
        incomingSession?.cleanupActiveTempFile()
        incomingSession = nil
        outgoingCancelRequested = true
        let acceptW = batchAcceptWaiter
        let resultWaiters = Array(fileResultWaiters.values)
        batchAcceptWaiter = nil
        fileResultWaiters.removeAll()
        lock.unlock()

        acceptW?.resolve(BatchAcceptPayload(batchId: "", accepted: false, reason: reason))
        resultWaiters.forEach { $0.resolve(FileResultPayload(fileIndex: -1, ok: false, error: reason)) }

        if let client {
            try? client.sendJSON(type: .disconnect, value: [String: String]())
            client.closeSocket()
        }
        if hadClient {
            onEvent(.peerDisconnected(reason: reason))
        }
    }

    public func cancelCurrentTransfer(reason: String = "Передача отменена на MacBook") {
        lock.lock()
        let client = activeClient
        let incomingActive = incomingSession != nil
        if let incoming = incomingSession {
            incoming.cancelled = true
            incoming.cleanupActiveTempFile()
            if incoming.approved == nil {
                // Reject awaiting request too
                let batchId = incoming.batch.batchId
                incomingSession = nil
                lock.unlock()
                try? client?.sendJSON(type: .batchAccept, value: BatchAcceptPayload(batchId: batchId, accepted: false, reason: reason))
                onEvent(.transferCancelled(reason: reason))
                return
            }
        }
        let outgoingActive = isOutgoingActiveFlag
        if outgoingActive {
            outgoingCancelRequested = true
        }
        let acceptW = batchAcceptWaiter
        let resultWaiters = Array(fileResultWaiters.values)
        lock.unlock()

        if incomingActive, let client {
            try? client.sendJSON(type: .cancel, value: CancelPayload(reason: reason, target: "outgoing"))
            onEvent(.transferCancelled(reason: reason))
        }
        if outgoingActive, let client {
            acceptW?.resolve(BatchAcceptPayload(batchId: "", accepted: false, reason: reason))
            resultWaiters.forEach { $0.resolve(FileResultPayload(fileIndex: -1, ok: false, error: reason)) }
            try? client.sendJSON(type: .cancel, value: CancelPayload(reason: reason, target: "incoming"))
        }
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        let client = activeClient
        listenFD = -1
        activeClient = nil
        activeSessionID = nil
        isRunningFlag = false
        incomingSession?.cancelled = true
        incomingSession?.cleanupActiveTempFile()
        incomingSession = nil
        outgoingCancelRequested = true
        let acceptW = batchAcceptWaiter
        let resultWaiters = Array(fileResultWaiters.values)
        let pairingWs = Array(pendingPairingWaiters.values)
        batchAcceptWaiter = nil
        fileResultWaiters.removeAll()
        pendingPairingWaiters.removeAll()
        lock.unlock()

        pairingWs.forEach { $0.resolve(false) }
        acceptW?.resolve(BatchAcceptPayload(batchId: "", accepted: false, reason: "Сервер остановлен"))
        resultWaiters.forEach { $0.resolve(FileResultPayload(fileIndex: -1, ok: false, error: "Сервер остановлен")) }

        client?.closeSocket()
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            onEvent(.stopped)
        }
    }

    private func reserveUnauthenticatedSlot(for remoteIP: String) -> Bool {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }

        guard isRunningFlag else { return false }
        if var record = authAttemptsByIP[remoteIP] {
            if let blockedUntil = record.blockedUntil {
                if now < blockedUntil {
                    return false
                }
                record.blockedUntil = nil
                record.count = 0
                record.windowStart = now
                authAttemptsByIP[remoteIP] = record
            }
        }
        guard unauthenticatedConnections < Self.maxUnauthenticatedConnections else {
            return false
        }
        unauthenticatedConnections += 1
        return true
    }

    private func recordAuthFailure(for remoteIP: String) -> Int {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }

        if authAttemptsByIP.count >= 256 {
            authAttemptsByIP = authAttemptsByIP.filter { _, rec in
                (rec.blockedUntil.map { $0 > now } ?? false) ||
                now.timeIntervalSince(rec.windowStart) < Self.authWindowSeconds
            }
            if authAttemptsByIP.count >= 256 {
                authAttemptsByIP.removeAll()
            }
        }

        var record = authAttemptsByIP[remoteIP] ?? AuthAttemptRecord(count: 0, windowStart: now, blockedUntil: nil)
        if now.timeIntervalSince(record.windowStart) >= Self.authWindowSeconds {
            record.count = 0
            record.windowStart = now
        }
        record.count += 1
        if record.count >= Self.maxFailedAuthAttempts {
            record.blockedUntil = now.addingTimeInterval(Self.authBlockSeconds)
        }
        authAttemptsByIP[remoteIP] = record
        return record.count
    }

    private func clearAuthFailures(for remoteIP: String) {
        lock.lock()
        authAttemptsByIP.removeValue(forKey: remoteIP)
        lock.unlock()
    }

    private func hasSufficientDiskSpace(requiredBytes: UInt64, at directory: URL) -> Bool {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let availableInt64 = values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
        guard let availableInt64, availableInt64 >= 0 else {
            return true
        }
        let available = UInt64(availableInt64)
        let needed = requiredBytes > (UInt64.max - Self.diskFreeMarginBytes)
            ? UInt64.max
            : (requiredBytes + Self.diskFreeMarginBytes)
        return available >= needed
    }

    private func acceptLoop(listenFD: Int32) {
        while true {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.accept(listenFD, saPtr, &addrLen)
                }
            }

            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }

            var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addrCopy = clientAddr.sin_addr
            inet_ntop(AF_INET, &addrCopy, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
            let remoteIP = String(
                decoding: ipBuffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )

            guard reserveUnauthenticatedSlot(for: remoteIP) else {
                Darwin.close(clientFD)
                continue
            }

            let stream = SocketStream(fd: clientFD)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(stream: stream, remoteIP: remoteIP)
            }
        }
    }

    private func handleClient(stream: SocketStream, remoteIP: String) {
        var peerConnectedEmitted = false
        var holdsUnauthSlot = true
        defer {
            var shouldEmitDisconnect = false
            var acceptW: OutgoingWaiter<BatchAcceptPayload>?
            var resultWs: [OutgoingWaiter<FileResultPayload>] = []

            lock.lock()
            if holdsUnauthSlot && unauthenticatedConnections > 0 {
                unauthenticatedConnections -= 1
            }
            if activeSessionID == stream.sessionID {
                activeClient = nil
                activeSessionID = nil
                incomingSession?.cleanupActiveTempFile()
                incomingSession = nil
                outgoingCancelRequested = true
                acceptW = batchAcceptWaiter
                resultWs = Array(fileResultWaiters.values)
                batchAcceptWaiter = nil
                fileResultWaiters.removeAll()
                shouldEmitDisconnect = peerConnectedEmitted
            }
            lock.unlock()

            acceptW?.resolve(BatchAcceptPayload(batchId: "", accepted: false, reason: "Соединение закрыто"))
            resultWs.forEach { $0.resolve(FileResultPayload(fileIndex: -1, ok: false, error: "Соединение закрыто")) }

            stream.closeSocket()
            if shouldEmitDisconnect {
                onEvent(.peerDisconnected(reason: nil))
            }
        }

        do {
            let helloFrame = try stream.readFrame()
            guard helloFrame.type == .hello else {
                _ = recordAuthFailure(for: remoteIP)
                try? stream.sendJSON(
                    type: .helloAck,
                    value: HelloAckPayload(ok: false, error: "Ожидался HELLO")
                )
                return
            }

            let hello = try FrameCodec.decodeJSON(HelloPayload.self, from: helloFrame.payload)
            guard let clientPubData = Data(base64Encoded: hello.clientPub),
                  clientPubData.count == 65,
                  let clientNonceData = Data(base64Encoded: hello.clientNonce),
                  clientNonceData.count == 32,
                  let clientProofData = Data(base64Encoded: hello.clientProof),
                  clientProofData.count == 32 else {
                _ = recordAuthFailure(for: remoteIP)
                try? stream.sendJSON(
                    type: .helloAck,
                    value: HelloAckPayload(ok: false, error: "Некорректные данные рукопожатия")
                )
                return
            }

            lock.lock()
            let expectedToken = token
            lock.unlock()

            let psk = SecureChannel.derivePSK(from: expectedToken)
            let expectedProof = SecureChannel.computeClientProof(
                psk: psk,
                clientPub: clientPubData,
                clientNonce: clientNonceData
            )

            guard SecureChannel.constantTimeEquals(clientProofData, expectedProof) else {
                let failCount = recordAuthFailure(for: remoteIP)
                try? stream.sendJSON(
                    type: .helloAck,
                    value: HelloAckPayload(ok: false, error: "Неверный токен QR-кода")
                )
                if failCount <= 3 {
                    onEvent(.error("Отклонено подключение с неверным токеном (\(remoteIP))"))
                }
                return
            }

            let peerPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: clientPubData)
            let serverPrivateKey = P256.KeyAgreement.PrivateKey()
            let serverPublicData = serverPrivateKey.publicKey.x963Representation
            let sharedSecret = try serverPrivateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
            let serverNonceData = SecureChannel.randomBytes(count: 32)
            let serverProofData = SecureChannel.computeServerProof(
                psk: psk,
                clientPub: clientPubData,
                serverPub: serverPublicData,
                clientNonce: clientNonceData,
                serverNonce: serverNonceData
            )

            try stream.sendJSON(
                type: .helloAck,
                value: HelloAckPayload(
                    ok: true,
                    serverPub: serverPublicData.base64EncodedString(),
                    serverNonce: serverNonceData.base64EncodedString(),
                    serverProof: serverProofData.base64EncodedString(),
                    error: nil
                )
            )

            // Upgrade wire socket to mutually authenticated AES-256-GCM before receiving peer identity.
            let sessionCipher = SecureChannel.SessionCipher(
                sharedSecret: sharedSecret,
                psk: psk,
                clientNonce: clientNonceData,
                serverNonce: serverNonceData,
                role: .server
            )
            stream.enableCipher(sessionCipher)

            let identityFrame = try stream.readFrame()
            guard identityFrame.type == .authIdentity else {
                return
            }
            let identity = try FrameCodec.decodeJSON(AuthIdentityPayload.self, from: identityFrame.payload)
            let sanitizedPeerName = SecureChannel.sanitizeDisplayText(identity.deviceName)
            let peerDisplayName = sanitizedPeerName.isEmpty ? "Android" : sanitizedPeerName

            lock.lock()
            let needsPairingApproval = requirePairingConfirmation
            lock.unlock()

            if needsPairingApproval {
                let requestId = UUID().uuidString
                let waiter = OutgoingWaiter<Bool>()
                lock.lock()
                pendingPairingWaiters[requestId] = waiter
                lock.unlock()

                onEvent(.incomingPairingRequest(IncomingPairingRequest(
                    requestId: requestId,
                    deviceName: peerDisplayName,
                    remoteIP: remoteIP
                )))

                var decision: Bool?
                let deadline = Date().addingTimeInterval(60)
                while decision == nil && Date() < deadline {
                    if let resolved = waiter.wait(timeoutSeconds: 0.25) {
                        decision = resolved
                        break
                    }
                    var peekByte: UInt8 = 0
                    let peekResult = Darwin.recv(stream.fd, &peekByte, 1, MSG_PEEK | MSG_DONTWAIT)
                    if peekResult == 0 || (peekResult < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                        break
                    }
                }

                lock.lock()
                pendingPairingWaiters.removeValue(forKey: requestId)
                lock.unlock()

                guard decision == true else {
                    onEvent(.incomingPairingCancelled(requestId: requestId))
                    let reason = decision == false
                        ? "Подключение отклонено на MacBook"
                        : "Время ожидания подтверждения на MacBook истекло"
                    let localName = SecureChannel.sanitizeDisplayText(currentDeviceName)
                    try? stream.sendJSON(
                        type: .authResult,
                        value: AuthResultPayload(
                            ok: false,
                            deviceName: localName.isEmpty ? "Droply" : localName,
                            error: reason
                        )
                    )
                    if decision == false {
                        onEvent(.transferCancelled(reason: reason))
                    }
                    return
                }
            }

            clearAuthFailures(for: remoteIP)
            stream.setReceiveTimeout(seconds: 65)

            lock.lock()
            if holdsUnauthSlot {
                holdsUnauthSlot = false
                if unauthenticatedConnections > 0 {
                    unauthenticatedConnections -= 1
                }
            }
            let previousClient = activeClient
            let hadPrevious = activeSessionID != nil
            activeClient = stream
            activeSessionID = stream.sessionID
            activePeerName = peerDisplayName
            incomingSession?.cleanupActiveTempFile()
            incomingSession = nil
            outgoingCancelRequested = true
            let oldAcceptW = batchAcceptWaiter
            let oldResultWs = Array(fileResultWaiters.values)
            batchAcceptWaiter = nil
            fileResultWaiters.removeAll()
            lock.unlock()

            oldAcceptW?.resolve(BatchAcceptPayload(batchId: "", accepted: false, reason: "Новое подключение"))
            oldResultWs.forEach { $0.resolve(FileResultPayload(fileIndex: -1, ok: false, error: "Новое подключение")) }

            if let previousClient {
                try? previousClient.sendJSON(type: .disconnect, value: [String: String]())
                previousClient.closeSocket()
            }
            if hadPrevious {
                onEvent(.peerDisconnected(reason: "Предыдущее подключение заменено новым"))
            }

            let sanitizedServerName = SecureChannel.sanitizeDisplayText(currentDeviceName)
            try stream.sendJSON(
                type: .authResult,
                value: AuthResultPayload(
                    ok: true,
                    deviceName: sanitizedServerName.isEmpty ? "Droply" : sanitizedServerName,
                    error: nil
                )
            )
            peerConnectedEmitted = true
            onEvent(.peerConnected(deviceName: peerDisplayName, remoteIP: remoteIP))

            try runSessionLoop(stream: stream, peerName: peerDisplayName)
        } catch FrameCodecError.unexpectedEOF {
            // Normal close
        } catch {
            lock.lock()
            let isCurrent = activeSessionID == stream.sessionID && isRunningFlag
            lock.unlock()
            if isCurrent {
                onEvent(.error(error.localizedDescription))
            }
        }
    }

    private func runSessionLoop(stream: SocketStream, peerName: String) throws {
        while true {
            let frame = try stream.readFrame()
            switch frame.type {
            case .ping:
                try stream.sendJSON(type: .pong, value: [String: String]())

            case .pong:
                break

            case .disconnect:
                return

            case .batchAccept:
                let accept = try FrameCodec.decodeJSON(BatchAcceptPayload.self, from: frame.payload)
                lock.lock()
                let waiter = batchAcceptWaiter
                lock.unlock()
                waiter?.resolve(accept)

            case .progressAck:
                let ack = try FrameCodec.decodeJSON(ProgressAckPayload.self, from: frame.payload)
                lock.lock()
                outgoingConfirmedBytes = max(outgoingConfirmedBytes, ack.batchBytesReceived)
                outgoingConfirmedPercent = max(outgoingConfirmedPercent, min(100.0, max(0.0, ack.percent)))
                let start = outgoingStartMs
                let totalFiles = outgoingTotalFiles
                let fileName = outgoingCurrentFileName
                let active = isOutgoingActiveFlag
                lock.unlock()

                if active {
                    let elapsed = max(Date().timeIntervalSince(start), 0.001)
                    let speed = Double(ack.batchBytesReceived) / elapsed
                    onEvent(.progress(TransferProgressSnapshot(
                        fileIndex: ack.fileIndex,
                        totalFiles: totalFiles,
                        currentFileName: fileName,
                        fileBytesReceived: ack.fileBytesReceived,
                        fileTotalBytes: ack.totalBytes,
                        batchBytesReceived: ack.batchBytesReceived,
                        batchTotalBytes: ack.totalBytes,
                        percent: min(100.0, max(0.0, ack.percent)),
                        speedBytesPerSecond: speed,
                        isIncoming: false
                    )))
                }

            case .fileResult:
                let res = try FrameCodec.decodeJSON(FileResultPayload.self, from: frame.payload)
                lock.lock()
                let waiter = fileResultWaiters.removeValue(forKey: res.fileIndex)
                lock.unlock()
                waiter?.resolve(res)

            case .batchStart:
                let batch = try FrameCodec.decodeJSON(BatchStartPayload.self, from: frame.payload)
                guard batch.totalFiles > 0,
                      batch.totalFiles <= Self.maxBatchFiles,
                      batch.totalBytes <= Self.maxBatchBytes else {
                    try stream.sendJSON(
                        type: .batchAccept,
                        value: BatchAcceptPayload(batchId: batch.batchId, accepted: false, reason: "Некорректные параметры передачи")
                    )
                    break
                }

                lock.lock()
                let destDir = destinationDirectory
                let overwrite = overwriteExisting
                let needsApproval = requireIncomingConfirmation
                lock.unlock()

                guard hasSufficientDiskSpace(requiredBytes: batch.totalBytes, at: destDir) else {
                    try stream.sendJSON(
                        type: .batchAccept,
                        value: BatchAcceptPayload(batchId: batch.batchId, accepted: false, reason: "Недостаточно места на диске MacBook")
                    )
                    onEvent(.error("Недостаточно места на диске для приёма файлов"))
                    break
                }

                lock.lock()
                incomingSession?.cleanupActiveTempFile()
                let session = IncomingBatchSession(
                    batch: batch,
                    baseDir: destDir,
                    overwrite: overwrite,
                    approved: needsApproval ? nil : true
                )
                incomingSession = session
                lock.unlock()

                let sanitizedPreview = batch.previewName.map { SecureChannel.sanitizeDisplayText($0, maxLength: 120) }
                if needsApproval {
                    onEvent(.incomingBatchRequest(IncomingBatchRequest(
                        batchId: batch.batchId,
                        senderName: peerName,
                        totalFiles: batch.totalFiles,
                        totalBytes: batch.totalBytes,
                        previewName: sanitizedPreview
                    )))
                } else {
                    try stream.sendJSON(
                        type: .batchAccept,
                        value: BatchAcceptPayload(batchId: batch.batchId, accepted: true, reason: nil)
                    )
                    onEvent(.batchStarted(
                        batchId: batch.batchId,
                        totalFiles: batch.totalFiles,
                        totalBytes: batch.totalBytes,
                        isIncoming: true
                    ))
                }

            case .fileStart:
                lock.lock()
                let session = incomingSession
                lock.unlock()
                guard let session else { break }
                if session.cancelled || session.approved != true { continue }

                session.cleanupActiveTempFile()
                let fileStart = try FrameCodec.decodeJSON(FileStartPayload.self, from: frame.payload)
                guard session.completedFilesCount < session.batch.totalFiles,
                      session.batchBytesReceived <= session.batch.totalBytes,
                      fileStart.size <= (session.batch.totalBytes - session.batchBytesReceived) else {
                    session.cancelled = true
                    let reason = "Превышен заявленный размер или количество файлов"
                    try stream.sendJSON(
                        type: .fileResult,
                        value: FileResultPayload(fileIndex: fileStart.fileIndex, ok: false, savedPath: nil, error: reason)
                    )
                    onEvent(.error(reason))
                    continue
                }

                let finalURL = try PathSanitizer.resolveDestinationURL(
                    baseDirectory: session.baseDir,
                    relativePath: fileStart.relativePath,
                    overwriteExisting: session.overwrite
                )
                let parentDir = finalURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

                let canonicalBase = session.baseDir.resolvingSymlinksInPath()
                let canonicalParent = parentDir.resolvingSymlinksInPath()
                let basePrefix = canonicalBase.path.hasSuffix("/") ? canonicalBase.path : canonicalBase.path + "/"
                guard canonicalParent.path == canonicalBase.path || canonicalParent.path.hasPrefix(basePrefix) else {
                    throw PathSanitizerError.unsafePath(fileStart.relativePath)
                }

                let tempURL = parentDir.appendingPathComponent(".\(UUID().uuidString).droply.part")
                FileManager.default.createFile(atPath: tempURL.path, contents: nil)
                let handle = try FileHandle(forWritingTo: tempURL)

                session.currentFileStart = fileStart
                session.currentFinalURL = finalURL
                session.currentTempURL = tempURL
                session.currentHandle = handle
                session.currentHasher = SHA256()
                session.currentFileBytes = 0

                onEvent(.fileStarted(
                    fileIndex: fileStart.fileIndex,
                    totalFiles: session.batch.totalFiles,
                    relativePath: fileStart.relativePath,
                    fileSize: fileStart.size,
                    isText: fileStart.isText
                ))
                emitIncomingProgress(session: session, stream: stream, forceAck: true)

            case .fileChunk:
                lock.lock()
                let session = incomingSession
                lock.unlock()
                guard let session else { break }
                if session.cancelled || session.approved != true { continue }

                guard let fileStart = session.currentFileStart,
                      let handle = session.currentHandle else {
                    throw FrameCodecError.socketError("Получен чанк без FILE_START")
                }
                let chunkLen = UInt64(frame.payload.count)
                if !frame.payload.isEmpty {
                    guard session.currentFileBytes <= fileStart.size,
                          chunkLen <= (fileStart.size - session.currentFileBytes),
                          session.batchBytesReceived <= session.batch.totalBytes,
                          chunkLen <= (session.batch.totalBytes - session.batchBytesReceived) else {
                        session.cancelled = true
                        session.cleanupActiveTempFile()
                        let reason = "Превышен заявленный размер файла \(fileStart.relativePath)"
                        try? stream.sendJSON(
                            type: .fileResult,
                            value: FileResultPayload(fileIndex: fileStart.fileIndex, ok: false, savedPath: nil, error: reason)
                        )
                        onEvent(.error(reason))
                        continue
                    }
                    try handle.write(contentsOf: frame.payload)
                    session.currentHasher.update(data: frame.payload)
                    session.currentFileBytes &+= chunkLen
                    session.batchBytesReceived &+= chunkLen
                }
                emitIncomingProgress(session: session, stream: stream, forceAck: false)

            case .fileEnd:
                lock.lock()
                let session = incomingSession
                lock.unlock()
                guard let session else { break }
                if session.cancelled || session.approved != true { continue }

                guard let fileStart = session.currentFileStart,
                      let tempURL = session.currentTempURL,
                      let finalURL = session.currentFinalURL,
                      let handle = session.currentHandle else {
                    throw FrameCodecError.socketError("Получен FILE_END без активного файла")
                }
                let fileEnd = try FrameCodec.decodeJSON(FileEndPayload.self, from: frame.payload)
                try handle.synchronize()
                try handle.close()
                session.currentHandle = nil

                let computedHex = session.currentHasher.finalize().map { String(format: "%02x", $0) }.joined()
                let expectedHex = fileEnd.sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

                if session.currentFileBytes != fileStart.size || expectedHex.count != 64 || computedHex != expectedHex {
                    try? FileManager.default.removeItem(at: tempURL)
                    let reason = "Ошибка целостности файла \(fileStart.relativePath)"
                    try stream.sendJSON(
                        type: .fileResult,
                        value: FileResultPayload(fileIndex: fileStart.fileIndex, ok: false, savedPath: nil, error: reason)
                    )
                    session.currentTempURL = nil
                    session.currentFinalURL = nil
                    session.currentFileStart = nil
                    onEvent(.error(reason))
                } else {
                    guard !PathSanitizer.isSymlink(atPath: finalURL.path),
                          !PathSanitizer.isDirectory(atPath: finalURL.path) else {
                        try? FileManager.default.removeItem(at: tempURL)
                        throw PathSanitizerError.unsafePath(fileStart.relativePath)
                    }
                    if session.overwrite && FileManager.default.fileExists(atPath: finalURL.path) {
                        try FileManager.default.removeItem(at: finalURL)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: finalURL)

                    session.completedFilesCount += 1
                    emitIncomingProgress(session: session, stream: stream, forceAck: true)

                    try stream.sendJSON(
                        type: .fileResult,
                        value: FileResultPayload(
                            fileIndex: fileStart.fileIndex,
                            ok: true,
                            savedPath: finalURL.path,
                            error: nil
                        )
                    )

                    let record = ReceivedFileRecord(
                        fileName: finalURL.lastPathComponent,
                        relativePath: fileStart.relativePath,
                        savedURL: finalURL,
                        size: session.currentFileBytes,
                        isText: fileStart.isText,
                        isIncoming: true,
                        sha256: computedHex
                    )
                    session.currentTempURL = nil
                    session.currentFinalURL = nil
                    session.currentFileStart = nil
                    onEvent(.fileCompleted(record))
                }

            case .batchEnd:
                let end = try FrameCodec.decodeJSON(BatchEndPayload.self, from: frame.payload)
                lock.lock()
                let session = incomingSession
                if session?.batch.batchId == end.batchId {
                    session?.cleanupActiveTempFile()
                    incomingSession = nil
                }
                lock.unlock()

                if let session, !session.cancelled, session.approved == true {
                    onEvent(.batchCompleted(batchId: end.batchId, fileCount: session.completedFilesCount, isIncoming: true))
                }

            case .cancel:
                let cancel = try FrameCodec.decodeJSON(CancelPayload.self, from: frame.payload)
                let target = cancel.target ?? "any"
                var notifyCancelled = false

                if target == "incoming" || target == "any" {
                    lock.lock()
                    if let session = incomingSession {
                        session.cancelled = true
                        session.cleanupActiveTempFile()
                        incomingSession = nil
                        notifyCancelled = true
                    }
                    lock.unlock()
                }
                if target == "outgoing" || target == "any" {
                    lock.lock()
                    let wasOutgoing = isOutgoingActiveFlag
                    outgoingCancelRequested = true
                    let acceptW = batchAcceptWaiter
                    let resultWs = Array(fileResultWaiters.values)
                    batchAcceptWaiter = nil
                    fileResultWaiters.removeAll()
                    lock.unlock()
                    if wasOutgoing {
                        acceptW?.resolve(BatchAcceptPayload(batchId: "", accepted: false, reason: cancel.reason))
                        resultWs.forEach { $0.resolve(FileResultPayload(fileIndex: -1, ok: false, error: cancel.reason)) }
                        notifyCancelled = true
                    }
                }
                if notifyCancelled {
                    onEvent(.transferCancelled(reason: cancel.reason))
                }

            default:
                break
            }
        }
    }

    private func emitIncomingProgress(session: IncomingBatchSession, stream: SocketStream, forceAck: Bool) {
        guard let fileStart = session.currentFileStart else { return }
        let now = Date()
        let bytesDelta = session.batchBytesReceived &- session.lastAckBytes
        let elapsedSinceAck = now.timeIntervalSince(session.lastAckTime)
        guard forceAck || bytesDelta >= 512 * 1024 || elapsedSinceAck >= 0.08 else {
            return
        }
        session.lastAckTime = now
        session.lastAckBytes = session.batchBytesReceived

        let totalElapsed = max(now.timeIntervalSince(session.batchStartTime), 0.001)
        let speed = Double(session.batchBytesReceived) / totalElapsed
        let percent: Double
        if session.batch.totalBytes == 0 {
            percent = session.batch.totalFiles > 0
                ? (Double(session.completedFilesCount) * 100.0 / Double(session.batch.totalFiles))
                : 100.0
        } else {
            percent = min(100.0, (Double(session.batchBytesReceived) * 100.0) / Double(session.batch.totalBytes))
        }

        let snapshot = TransferProgressSnapshot(
            fileIndex: fileStart.fileIndex,
            totalFiles: session.batch.totalFiles,
            currentFileName: URL(fileURLWithPath: fileStart.relativePath).lastPathComponent,
            fileBytesReceived: session.currentFileBytes,
            fileTotalBytes: fileStart.size,
            batchBytesReceived: session.batchBytesReceived,
            batchTotalBytes: session.batch.totalBytes,
            percent: percent,
            speedBytesPerSecond: speed,
            isIncoming: true
        )
        onEvent(.progress(snapshot))

        let ack = ProgressAckPayload(
            fileIndex: fileStart.fileIndex,
            fileBytesReceived: session.currentFileBytes,
            batchBytesReceived: session.batchBytesReceived,
            totalBytes: session.batch.totalBytes,
            percent: percent
        )
        try? stream.sendJSON(type: .progressAck, value: ack)
    }
}

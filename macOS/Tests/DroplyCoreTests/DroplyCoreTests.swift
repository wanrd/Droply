import CryptoKit
import Darwin
import Foundation
import Testing
@testable import DroplyCore

@Suite("DroplyCore Tests")
struct DroplyCoreTests {

    @Test("PathSanitizer blocks traversal and resolves unique names")
    func testPathSanitizer() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroplyPathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        #expect(throws: PathSanitizerError.self) {
            try PathSanitizer.sanitizedComponents(from: "../secret.txt")
        }
        #expect(throws: PathSanitizerError.self) {
            try PathSanitizer.sanitizedComponents(from: "/etc/passwd")
        }
        #expect(throws: PathSanitizerError.self) {
            try PathSanitizer.sanitizedComponents(from: "Folder/../secret.txt")
        }
        #expect(throws: PathSanitizerError.self) {
            try PathSanitizer.sanitizedComponents(from: "")
        }

        let resolved1 = try PathSanitizer.resolveDestinationURL(
            baseDirectory: tempRoot,
            relativePath: "Photos/Trip/img.jpg",
            overwriteExisting: false
        )
        #expect(resolved1.path.hasSuffix("Photos/Trip/img.jpg"))

        try FileManager.default.createDirectory(at: resolved1.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: resolved1)

        let resolved2 = try PathSanitizer.resolveDestinationURL(
            baseDirectory: tempRoot,
            relativePath: "Photos/Trip/img.jpg",
            overwriteExisting: false
        )
        #expect(resolved2.lastPathComponent == "img (1).jpg")

        let resolvedOverwrite = try PathSanitizer.resolveDestinationURL(
            baseDirectory: tempRoot,
            relativePath: "Photos/Trip/img.jpg",
            overwriteExisting: true
        )
        #expect(resolvedOverwrite.lastPathComponent == "img.jpg")
    }

    @Test("QRPairingPayload JSON roundtrip")
    func testQRPairingJSON() throws {
        let payload = QRPairingPayload(
            host: "192.168.1.20",
            hosts: ["192.168.1.20"],
            port: 45820,
            token: "abcdef0123456789",
            name: "MacBook Pro"
        )
        let json = try payload.toJSONString()
        let decoded = try JSONDecoder().decode(QRPairingPayload.self, from: Data(json.utf8))
        #expect(decoded == payload)
    }

    @Test("End-to-end TCP transfer of text, folder files, empty file, and chunked binary")
    func testEndToEndTransfer() async throws {
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroplyServerTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        let recorder = EventRecorder()
        let server = DroplyServer(
            destinationDirectory: destDir,
            overwriteExisting: false,
            requireIncomingConfirmation: false,
            deviceName: "TestMac"
        ) { event in
            recorder.append(event)
        }
        try server.start(port: 0)
        defer { server.stop() }

        let port = server.currentPort
        let token = server.currentToken
        #expect(port > 0)

        let clientFD = try connectLocalhost(port: port)
        defer { Darwin.close(clientFD) }

        let (cipher, authResult) = try authenticateSession(fd: clientFD, token: token, deviceName: "Pixel 9")
        #expect(authResult.ok == true)
        #expect(authResult.deviceName == "TestMac")

        let textData = Data("Привет из Android по Wi-Fi!\nСтрока 2.".utf8)
        var binaryBytes = [UInt8](repeating: 0, count: 1_200_000)
        for i in binaryBytes.indices {
            binaryBytes[i] = UInt8(i % 251)
        }
        let binaryData = Data(binaryBytes)
        let emptyData = Data()

        let totalBytes = UInt64(textData.count + binaryData.count + emptyData.count)
        let batchId = UUID().uuidString
        try sendEncryptedJSON(fd: clientFD, cipher: cipher, type: .batchStart, json: BatchStartPayload(batchId: batchId, totalFiles: 3, totalBytes: totalBytes))

        let acceptFrame = try readEncryptedFrame(fd: clientFD, cipher: cipher)
        #expect(acceptFrame.type == .batchAccept)
        let accept = try FrameCodec.decodeJSON(BatchAcceptPayload.self, from: acceptFrame.payload)
        #expect(accept.accepted == true)

        try sendEncryptedFile(fd: clientFD, cipher: cipher, index: 0, relativePath: "Notes/2026/hello.txt", data: textData, isText: true)
        try sendEncryptedFile(fd: clientFD, cipher: cipher, index: 1, relativePath: "Video/sample.bin", data: binaryData, isText: false)
        try sendEncryptedFile(fd: clientFD, cipher: cipher, index: 2, relativePath: "empty.txt", data: emptyData, isText: true)
        try sendEncryptedJSON(fd: clientFD, cipher: cipher, type: .batchEnd, json: BatchEndPayload(batchId: batchId))

        var results: [FileResultPayload] = []
        var sawProgress100 = false
        while results.count < 3 {
            let frame = try readEncryptedFrame(fd: clientFD, cipher: cipher)
            switch frame.type {
            case .progressAck:
                let prog = try FrameCodec.decodeJSON(ProgressAckPayload.self, from: frame.payload)
                if prog.percent >= 99.9 {
                    sawProgress100 = true
                }
            case .fileResult:
                let res = try FrameCodec.decodeJSON(FileResultPayload.self, from: frame.payload)
                results.append(res)
            default:
                break
            }
        }

        #expect(results.allSatisfy { $0.ok })
        #expect(sawProgress100)

        let savedText = try Data(contentsOf: destDir.appendingPathComponent("Notes/2026/hello.txt"))
        let savedBin = try Data(contentsOf: destDir.appendingPathComponent("Video/sample.bin"))
        let savedEmpty = try Data(contentsOf: destDir.appendingPathComponent("empty.txt"))
        #expect(savedText == textData)
        #expect(savedBin == binaryData)
        #expect(savedEmpty.isEmpty)

        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.completedFilesCount == 3)
        #expect(recorder.sawBatchCompleted)
    }

    @Test("Incoming batch confirmation accepts and rejects explicitly")
    func testIncomingConfirmationAcceptAndReject() async throws {
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroplyConfirmTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        let server = DroplyServer(
            destinationDirectory: destDir,
            overwriteExisting: false,
            requireIncomingConfirmation: true
        ) { event in
            if case .incomingBatchRequest(let req) = event {
                if req.previewName == "reject.txt" {
                    // Reject first batch
                    Task {
                        try? await Task.sleep(for: .milliseconds(20))
                        // Captured server below isn't needed if handled outside; handled below
                    }
                }
            }
        }

        let box = ServerBox()
        let confirmServer = DroplyServer(
            destinationDirectory: destDir,
            overwriteExisting: false,
            requireIncomingConfirmation: true
        ) { event in
            if case .incomingBatchRequest(let req) = event {
                let accept = req.previewName != "reject.txt"
                box.server?.respondToIncomingBatch(batchId: req.batchId, accepted: accept)
            }
        }
        box.server = confirmServer
        _ = server

        try confirmServer.start(port: 0)
        defer { confirmServer.stop() }

        let clientFD = try connectLocalhost(port: confirmServer.currentPort)
        defer { Darwin.close(clientFD) }

        let (cipher, authResult) = try authenticateSession(fd: clientFD, token: confirmServer.currentToken, deviceName: "CPH2707")
        #expect(authResult.ok == true)

        // Batch 1: rejected
        try sendEncryptedJSON(fd: clientFD, cipher: cipher, type: .batchStart, json: BatchStartPayload(batchId: "b1", totalFiles: 1, totalBytes: 5, previewName: "reject.txt"))
        let res1 = try FrameCodec.decodeJSON(BatchAcceptPayload.self, from: readEncryptedFrame(fd: clientFD, cipher: cipher).payload)
        #expect(res1.batchId == "b1")
        #expect(res1.accepted == false)

        // Batch 2: accepted
        let okData = Data("Hello!".utf8)
        try sendEncryptedJSON(fd: clientFD, cipher: cipher, type: .batchStart, json: BatchStartPayload(batchId: "b2", totalFiles: 1, totalBytes: UInt64(okData.count), previewName: "accept.txt"))
        let res2 = try FrameCodec.decodeJSON(BatchAcceptPayload.self, from: readEncryptedFrame(fd: clientFD, cipher: cipher).payload)
        #expect(res2.batchId == "b2")
        #expect(res2.accepted == true)

        try sendEncryptedFile(fd: clientFD, cipher: cipher, index: 0, relativePath: "accept.txt", data: okData, isText: true)
        try sendEncryptedJSON(fd: clientFD, cipher: cipher, type: .batchEnd, json: BatchEndPayload(batchId: "b2"))

        var gotOk = false
        while !gotOk {
            let f = try readEncryptedFrame(fd: clientFD, cipher: cipher)
            if f.type == .fileResult {
                gotOk = try FrameCodec.decodeJSON(FileResultPayload.self, from: f.payload).ok
            }
        }
        #expect(gotOk)
        #expect(try Data(contentsOf: destDir.appendingPathComponent("accept.txt")) == okData)
    }

    @Test("Invalid token is rejected cleanly")
    func testInvalidTokenRejected() throws {
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroplyRejectTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        let server = DroplyServer(destinationDirectory: destDir, requireIncomingConfirmation: false) { _ in }
        try server.start(port: 0)
        defer { server.stop() }

        let clientFD = try connectLocalhost(port: server.currentPort)
        defer { Darwin.close(clientFD) }

        let hello = try makeHelloPacket(token: "wrong-token")
        try sendPlainJSON(fd: clientFD, type: .hello, json: hello.payload)
        let ackFrame = try readPlainFrame(fd: clientFD)
        let ack = try FrameCodec.decodeJSON(HelloAckPayload.self, from: ackFrame.payload)
        #expect(ack.ok == false)
    }

    @Test("Corrupted checksum cleans up temp file and returns failure")
    func testCorruptedChecksumCleansUp() throws {
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroplyHashTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        let server = DroplyServer(destinationDirectory: destDir, requireIncomingConfirmation: false) { _ in }
        try server.start(port: 0)
        defer { server.stop() }

        let clientFD = try connectLocalhost(port: server.currentPort)
        defer { Darwin.close(clientFD) }

        let (cipher, authResult) = try authenticateSession(fd: clientFD, token: server.currentToken, deviceName: "Pixel")
        #expect(authResult.ok == true)

        let payloadData = Data("important bytes".utf8)
        let batchId = UUID().uuidString
        try sendEncryptedJSON(fd: clientFD, cipher: cipher, type: .batchStart, json: BatchStartPayload(batchId: batchId, totalFiles: 1, totalBytes: UInt64(payloadData.count)))
        _ = try readEncryptedFrame(fd: clientFD, cipher: cipher) // batchAccept
        try sendEncryptedJSON(fd: clientFD, cipher: cipher, type: .fileStart, json: FileStartPayload(fileIndex: 0, relativePath: "bad.bin", size: UInt64(payloadData.count)))
        try sendEncryptedRaw(fd: clientFD, cipher: cipher, type: .fileChunk, payload: payloadData)
        try sendEncryptedJSON(fd: clientFD, cipher: cipher, type: .fileEnd, json: FileEndPayload(sha256: String(repeating: "0", count: 64)))
        try sendEncryptedJSON(fd: clientFD, cipher: cipher, type: .batchEnd, json: BatchEndPayload(batchId: batchId))

        var fileResult: FileResultPayload?
        while fileResult == nil {
            let frame = try readEncryptedFrame(fd: clientFD, cipher: cipher)
            if frame.type == .fileResult {
                fileResult = try FrameCodec.decodeJSON(FileResultPayload.self, from: frame.payload)
            }
        }

        #expect(fileResult?.ok == false)
        let contents = try FileManager.default.contentsOfDirectory(atPath: destDir.path)
        #expect(contents.isEmpty)
    }

    @Test("Cancel mid-transfer cleans up temp file and keeps session alive")
    func testCancelMidTransferAndResume() async throws {
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroplyCancelTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        let recorder = EventRecorder()
        let server = DroplyServer(destinationDirectory: destDir, requireIncomingConfirmation: false) { event in
            recorder.append(event)
        }
        try server.start(port: 0)
        defer { server.stop() }

        let clientFD = try connectLocalhost(port: server.currentPort)
        defer { Darwin.close(clientFD) }

        let (cipher, authResult) = try authenticateSession(fd: clientFD, token: server.currentToken, deviceName: "OnePlus")
        #expect(authResult.ok == true)

        let batch1 = UUID().uuidString
        try sendEncryptedJSON(fd: clientFD, cipher: cipher, type: .batchStart, json: BatchStartPayload(batchId: batch1, totalFiles: 1, totalBytes: 1000))
        _ = try readEncryptedFrame(fd: clientFD, cipher: cipher) // batchAccept
        try sendEncryptedJSON(fd: clientFD, cipher: cipher, type: .fileStart, json: FileStartPayload(fileIndex: 0, relativePath: "cancelled.txt", size: 1000, isText: true))
        try sendEncryptedRaw(fd: clientFD, cipher: cipher, type: .fileChunk, payload: Data("partial".utf8))
        try sendEncryptedJSON(fd: clientFD, cipher: cipher, type: .cancel, json: CancelPayload(reason: "Cancelled by test"))

        try await Task.sleep(for: .milliseconds(80))
        let afterCancelContents = try FileManager.default.contentsOfDirectory(atPath: destDir.path)
        #expect(afterCancelContents.isEmpty)

        let batch2 = UUID().uuidString
        let okData = Data("Recovered!".utf8)
        try sendEncryptedJSON(fd: clientFD, cipher: cipher, type: .batchStart, json: BatchStartPayload(batchId: batch2, totalFiles: 1, totalBytes: UInt64(okData.count)))
        // Drain any progressAck before batchAccept
        while true {
            let f = try readEncryptedFrame(fd: clientFD, cipher: cipher)
            if f.type == .batchAccept { break }
        }
        try sendEncryptedFile(fd: clientFD, cipher: cipher, index: 0, relativePath: "ok.txt", data: okData, isText: true)
        try sendEncryptedJSON(fd: clientFD, cipher: cipher, type: .batchEnd, json: BatchEndPayload(batchId: batch2))

        var gotOk = false
        while !gotOk {
            let frame = try readEncryptedFrame(fd: clientFD, cipher: cipher)
            if frame.type == .fileResult {
                let res = try FrameCodec.decodeJSON(FileResultPayload.self, from: frame.payload)
                gotOk = res.ok
            }
        }
        #expect(gotOk)
        #expect(try Data(contentsOf: destDir.appendingPathComponent("ok.txt")) == okData)
    }

    @Test("Reconnecting replaces old client without trailing disconnect overriding new peer")
    func testReconnectReplacesOldSessionCleanly() async throws {
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroplyReconnectTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        let recorder = EventRecorder()
        let server = DroplyServer(destinationDirectory: destDir, requireIncomingConfirmation: false) { event in
            recorder.append(event)
        }
        try server.start(port: 0)
        defer { server.stop() }

        let fd1 = try connectLocalhost(port: server.currentPort)
        defer { Darwin.close(fd1) }
        let (_, auth1) = try authenticateSession(fd: fd1, token: server.currentToken, deviceName: "Phone-1")
        #expect(auth1.ok == true)

        let fd2 = try connectLocalhost(port: server.currentPort)
        defer { Darwin.close(fd2) }
        let (_, auth2) = try authenticateSession(fd: fd2, token: server.currentToken, deviceName: "Phone-2")
        #expect(auth2.ok == true)

        try await Task.sleep(for: .milliseconds(120))
        #expect(recorder.lastConnectedName == "Phone-2")
        #expect(recorder.isCurrentlyConnected)
    }

    @Test("Pairing warning confirmation accepts and rejects connections")
    func testPairingConfirmationAcceptAndReject() throws {
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroplyPairConfirm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        let box = ServerBox()
        let server = DroplyServer(
            destinationDirectory: destDir,
            requireIncomingConfirmation: false,
            requirePairingConfirmation: true
        ) { event in
            if case .incomingPairingRequest(let req) = event {
                box.server?.respondToPairingRequest(requestId: req.requestId, accepted: req.deviceName == "AllowedPhone")
            }
        }
        box.server = server
        try server.start(port: 0)
        defer { server.stop() }

        let fdRejected = try connectLocalhost(port: server.currentPort)
        defer { Darwin.close(fdRejected) }
        let (_, authRejected) = try authenticateSession(fd: fdRejected, token: server.currentToken, deviceName: "BlockedPhone")
        #expect(authRejected.ok == false)

        let fdAllowed = try connectLocalhost(port: server.currentPort)
        defer { Darwin.close(fdAllowed) }
        let (_, authAllowed) = try authenticateSession(fd: fdAllowed, token: server.currentToken, deviceName: "AllowedPhone")
        #expect(authAllowed.ok == true)
    }

    @Test("NetworkUtils excludes VPN and loopback interfaces")
    func testNetworkUtilsExcludesVPN() {
        let ifaces = NetworkUtils.activeIPv4Interfaces()
        for iface in ifaces {
            #expect(!iface.name.hasPrefix("utun"))
            #expect(!iface.name.hasPrefix("lo"))
            #expect(!iface.name.hasPrefix("awdl"))
        }
    }

    @Test("DroplyServer updates device name and incoming confirmation dynamically")
    func testLiveServerSettingsUpdate() async throws {
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroplySettingsTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        let server = DroplyServer(
            destinationDirectory: destDir,
            overwriteExisting: false,
            requireIncomingConfirmation: true,
            deviceName: "OldMac"
        ) { _ in }
        server.updateDeviceName("StudioMac")
        server.updateRequireIncomingConfirmation(false)
        server.updateOverwriteExisting(true)
        try server.start(port: 0)
        defer { server.stop() }

        let fd = try connectLocalhost(port: server.currentPort)
        defer { Darwin.close(fd) }

        let (cipher, auth) = try authenticateSession(fd: fd, token: server.currentToken, deviceName: "Phone")
        #expect(auth.ok == true)
        #expect(auth.deviceName == "StudioMac")

        let data = Data("Auto accepted".utf8)
        let batchId = UUID().uuidString
        try sendEncryptedJSON(fd: fd, cipher: cipher, type: .batchStart, json: BatchStartPayload(batchId: batchId, totalFiles: 1, totalBytes: UInt64(data.count), previewName: "note.txt"))
        let accept = try FrameCodec.decodeJSON(BatchAcceptPayload.self, from: readEncryptedFrame(fd: fd, cipher: cipher).payload)
        #expect(accept.batchId == batchId)
        #expect(accept.accepted == true)
    }

    @Test("PathSanitizer blocks bidi overrides, control chars, deep paths, and symlink escapes")
    func testPathSanitizerSecurityHardening() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroplyHardening-\(UUID().uuidString)", isDirectory: true)
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroplyOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
            try? FileManager.default.removeItem(at: outsideDir)
        }

        #expect(throws: PathSanitizerError.self) {
            try PathSanitizer.sanitizedComponents(from: "invoice\u{202E}fdp.exe")
        }
        #expect(throws: PathSanitizerError.self) {
            try PathSanitizer.sanitizedComponents(from: "bad\nline.txt")
        }
        #expect(throws: PathSanitizerError.self) {
            try PathSanitizer.sanitizedComponents(from: Array(repeating: "a", count: 33).joined(separator: "/") + "/f.txt")
        }
        #expect(throws: PathSanitizerError.self) {
            try PathSanitizer.sanitizedComponents(from: String(repeating: "x", count: 260))
        }

        let escapeLink = tempRoot.appendingPathComponent("escapeLink")
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: outsideDir)
        #expect(throws: PathSanitizerError.self) {
            try PathSanitizer.resolveDestinationURL(
                baseDirectory: tempRoot,
                relativePath: "escapeLink/pwn.txt",
                overwriteExisting: true
            )
        }
    }

    @Test("MacFileCollector skips symbolic links safely")
    func testMacFileCollectorSkipsSymlinks() throws {
        let rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroplyCollector-\(UUID().uuidString)", isDirectory: true)
        let outsideFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroplySecret-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outsideFile)
        defer {
            try? FileManager.default.removeItem(at: rootDir)
            try? FileManager.default.removeItem(at: outsideFile)
        }

        let safeFile = rootDir.appendingPathComponent("normal.txt")
        try Data("ok".utf8).write(to: safeFile)
        let nestedLink = rootDir.appendingPathComponent("leak.txt")
        try FileManager.default.createSymbolicLink(at: nestedLink, withDestinationURL: outsideFile)

        let directResult = MacFileCollector.collect(urls: [nestedLink])
        #expect(directResult.isEmpty)

        let folderResult = MacFileCollector.collect(urls: [rootDir])
        #expect(folderResult.count == 1)
        #expect(folderResult.first?.relativePath.hasSuffix("normal.txt") == true)
    }

    @Test("Tampered encrypted frame terminates session without writing files")
    func testTamperedEncryptedFrameRejected() throws {
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroplyTamperTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        let server = DroplyServer(destinationDirectory: destDir, requireIncomingConfirmation: false) { _ in }
        try server.start(port: 0)
        defer { server.stop() }

        let fd = try connectLocalhost(port: server.currentPort)
        defer { Darwin.close(fd) }

        let (cipher, auth) = try authenticateSession(fd: fd, token: server.currentToken, deviceName: "Phone")
        #expect(auth.ok == true)

        let batchJson = try JSONEncoder().encode(BatchStartPayload(batchId: "b", totalFiles: 1, totalBytes: 5))
        var sealed = try cipher.sealPacket(type: .batchStart, plaintext: batchJson)
        sealed[sealed.count - 1] ^= 0x01
        try writeAll(fd: fd, data: sealed)

        #expect(throws: Error.self) {
            _ = try readEncryptedFrame(fd: fd, cipher: cipher)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destDir.path).isEmpty)
    }

    @Test("Empty SHA-256 checksum on FILE_END is rejected")
    func testEmptySHA256Rejected() throws {
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroplyEmptyShaTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        let server = DroplyServer(destinationDirectory: destDir, requireIncomingConfirmation: false) { _ in }
        try server.start(port: 0)
        defer { server.stop() }

        let fd = try connectLocalhost(port: server.currentPort)
        defer { Darwin.close(fd) }

        let (cipher, auth) = try authenticateSession(fd: fd, token: server.currentToken, deviceName: "Phone")
        #expect(auth.ok == true)

        let data = Data("hello".utf8)
        let batchId = UUID().uuidString
        try sendEncryptedJSON(fd: fd, cipher: cipher, type: .batchStart, json: BatchStartPayload(batchId: batchId, totalFiles: 1, totalBytes: UInt64(data.count)))
        _ = try readEncryptedFrame(fd: fd, cipher: cipher)
        try sendEncryptedJSON(fd: fd, cipher: cipher, type: .fileStart, json: FileStartPayload(fileIndex: 0, relativePath: "nosha.bin", size: UInt64(data.count)))
        try sendEncryptedRaw(fd: fd, cipher: cipher, type: .fileChunk, payload: data)
        try sendEncryptedJSON(fd: fd, cipher: cipher, type: .fileEnd, json: FileEndPayload(sha256: ""))
        try sendEncryptedJSON(fd: fd, cipher: cipher, type: .batchEnd, json: BatchEndPayload(batchId: batchId))

        var fileResult: FileResultPayload?
        while fileResult == nil {
            let f = try readEncryptedFrame(fd: fd, cipher: cipher)
            if f.type == .fileResult {
                fileResult = try FrameCodec.decodeJSON(FileResultPayload.self, from: f.payload)
            }
        }
        #expect(fileResult?.ok == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destDir.path).isEmpty)
    }

    @Test("Oversized FILE_CHUNK exceeding declared size is rejected")
    func testOversizedChunkRejected() throws {
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroplyOverflowTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        let server = DroplyServer(destinationDirectory: destDir, requireIncomingConfirmation: false) { _ in }
        try server.start(port: 0)
        defer { server.stop() }

        let fd = try connectLocalhost(port: server.currentPort)
        defer { Darwin.close(fd) }

        let (cipher, auth) = try authenticateSession(fd: fd, token: server.currentToken, deviceName: "Phone")
        #expect(auth.ok == true)

        let batchId = UUID().uuidString
        try sendEncryptedJSON(fd: fd, cipher: cipher, type: .batchStart, json: BatchStartPayload(batchId: batchId, totalFiles: 1, totalBytes: 5))
        _ = try readEncryptedFrame(fd: fd, cipher: cipher)
        try sendEncryptedJSON(fd: fd, cipher: cipher, type: .fileStart, json: FileStartPayload(fileIndex: 0, relativePath: "overflow.bin", size: 5))
        try sendEncryptedRaw(fd: fd, cipher: cipher, type: .fileChunk, payload: Data("0123456789".utf8))

        var fileResult: FileResultPayload?
        while fileResult == nil {
            let f = try readEncryptedFrame(fd: fd, cipher: cipher)
            if f.type == .fileResult {
                fileResult = try FrameCodec.decodeJSON(FileResultPayload.self, from: f.payload)
            }
        }
        #expect(fileResult?.ok == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destDir.path).isEmpty)
    }

    @Test("Auth rate limiter blocks IP after repeated failed token proofs")
    func testAuthRateLimiterBlocksAfterRepeatedFailures() throws {
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroplyRateLimit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        let server = DroplyServer(destinationDirectory: destDir, requireIncomingConfirmation: false) { _ in }
        try server.start(port: 0)
        defer { server.stop() }

        for _ in 0..<5 {
            let fd = try connectLocalhost(port: server.currentPort)
            defer { Darwin.close(fd) }
            let hello = try makeHelloPacket(token: "bad-token")
            try sendPlainJSON(fd: fd, type: .hello, json: hello.payload)
            let ack = try FrameCodec.decodeJSON(HelloAckPayload.self, from: readPlainFrame(fd: fd).payload)
            #expect(ack.ok == false)
        }

        let blockedFD = try connectLocalhost(port: server.currentPort)
        defer { Darwin.close(blockedFD) }
        #expect(throws: Error.self) {
            let hello = try makeHelloPacket(token: server.currentToken)
            try sendPlainJSON(fd: blockedFD, type: .hello, json: hello.payload)
            _ = try readPlainFrame(fd: blockedFD)
        }
    }

    @Test("AppUpdateChecker validates GitHub URLs, semantic versions, and safe parsing")
    func testAppUpdateCheckerSecurityAndParsing() throws {
        let parsed = AppUpdateChecker.parseRepository("https://github.com/islam-dev/Droply.git")
        #expect(parsed != nil)
        #expect(parsed?.owner == "islam-dev")
        #expect(parsed?.repo == "Droply")
        #expect(parsed?.releasesURL.absoluteString == "https://github.com/islam-dev/Droply/releases")

        #expect(AppUpdateChecker.parseRepository("http://github.com/islam/droply") == nil)
        #expect(AppUpdateChecker.parseRepository("https://evil.com/islam/droply") == nil)
        #expect(AppUpdateChecker.parseRepository("https://user@github.com/islam/droply") == nil)
        #expect(AppUpdateChecker.parseRepository("https://github.com/../etc/droply") == nil)
        #expect(AppUpdateChecker.parseRepository("") == nil)

        if let repo = parsed {
            #expect(
                AppUpdateChecker.validatedGitHubURL("https://github.com/islam-dev/Droply/releases/tag/v1.2", repo: repo).absoluteString
                    == "https://github.com/islam-dev/Droply/releases/tag/v1.2"
            )
            #expect(
                AppUpdateChecker.validatedGitHubURL("https://evil.example/payload.dmg", repo: repo) == repo.releasesURL
            )
            #expect(
                AppUpdateChecker.validatedGitHubURL("https://github.com/attacker/FakeDroply/releases", repo: repo) == repo.releasesURL
            )

            let releaseJSON = Data(#"{"tag_name":"v1.2.0","html_url":"https://github.com/islam-dev/Droply/releases/tag/v1.2.0","body":"Bug\u202Efixes","draft":false,"prerelease":false}"#.utf8)
            let info = AppUpdateChecker.parseReleaseResponse(data: releaseJSON, currentVersion: "1.0", repo: repo)
            #expect(info?.latestVersion == "1.2.0")
            #expect(info?.releaseURL.absoluteString == "https://github.com/islam-dev/Droply/releases/tag/v1.2.0")
            #expect(info?.releaseNotes?.contains("\u{202E}") == false)

            let draftJSON = Data(#"{"tag_name":"v2.0","draft":true,"prerelease":false}"#.utf8)
            #expect(AppUpdateChecker.parseReleaseResponse(data: draftJSON, currentVersion: "1.0", repo: repo) == nil)

            let tagsJSON = Data(#"[{"name":"v1.0"},{"name":"v1.3"},{"name":"v1.2"}]"#.utf8)
            let tagInfo = AppUpdateChecker.parseTagsResponse(data: tagsJSON, currentVersion: "1.1", repo: repo)
            #expect(tagInfo?.latestVersion == "1.3")
            #expect(tagInfo?.releaseURL == repo.releasesURL)

            let manifestJSON = Data(#"{"version":"1.4","macVersion":"1.6","title":"Срочный патч\u202E","notes":"Строка 1\nСтрока 2\u202E","releaseUrl":"https://evil.com/bad.dmg"}"#.utf8)
            let manifestInfo = AppUpdateChecker.parseManifestResponse(data: manifestJSON, currentVersion: "1.0", repo: repo)
            #expect(manifestInfo?.latestVersion == "1.6")
            #expect(manifestInfo?.title == "Срочный патч")
            #expect(manifestInfo?.releaseNotes == "Строка 1\nСтрока 2")
            #expect(manifestInfo?.releaseURL == repo.releasesURL)

            let releaseSameVer = AppUpdateChecker.parseReleaseResponse(
                data: Data(#"{"tag_name":"v1.6","html_url":"https://github.com/islam-dev/Droply/releases/tag/v1.6","body":"Default","draft":false,"prerelease":false}"#.utf8),
                currentVersion: "1.0",
                repo: repo
            )
            let preferred = AppUpdateChecker.resolvePreferredUpdate(
                release: releaseSameVer,
                manifest: manifestInfo,
                tags: nil,
                repo: repo
            )
            #expect(preferred?.title == "Срочный патч")
            #expect(preferred?.releaseNotes == "Строка 1\nСтрока 2")
            #expect(preferred?.releaseURL.absoluteString == "https://github.com/islam-dev/Droply/releases/tag/v1.6")

            let draftManifest = AdminUpdateManifest(
                version: "v1.7",
                macVersion: "",
                androidVersion: "1.8",
                title: "Важное\u{202E} обновление",
                notes: "Пункт 1\nПункт 2",
                releaseUrl: ""
            )
            let validatedManifest = try draftManifest.validated(for: repo)
            #expect(validatedManifest.version == "1.7")
            #expect(validatedManifest.macVersion == "1.7")
            #expect(validatedManifest.androidVersion == "1.8")
            #expect(validatedManifest.title == "Важное обновление")
            #expect(validatedManifest.releaseUrl == repo.releasesURL.absoluteString)
            let encoded = try validatedManifest.encodedJSONData()
            let reparsed = AppUpdateChecker.parseManifestResponse(data: encoded, currentVersion: "1.0", repo: repo)
            #expect(reparsed?.latestVersion == "1.7")

            let badManifest = AdminUpdateManifest(
                version: "1.2",
                macVersion: "1.2",
                androidVersion: "1.2",
                title: "Bad",
                notes: "Bad",
                releaseUrl: "https://evil.example/evil.dmg"
            )
            #expect(throws: AdminManifestError.self) {
                _ = try badManifest.validated(for: repo)
            }

            // Reject traversal URLs under same host/repo, non-numeric versions, empty notes, and >500-char notes
            let traversalManifest = AdminUpdateManifest(
                version: "1.2",
                macVersion: "1.2",
                androidVersion: "1.2",
                title: "OK",
                notes: "Текст",
                releaseUrl: "https://github.com/islam-dev/Droply/../../../evil"
            )
            #expect(throws: AdminManifestError.self) {
                _ = try traversalManifest.validated(for: repo)
            }

            let badVersionManifest = AdminUpdateManifest(
                version: "1.2 beta",
                macVersion: "1.2",
                androidVersion: "1.2",
                title: "OK",
                notes: "Текст",
                releaseUrl: ""
            )
            #expect(throws: AdminManifestError.self) {
                _ = try badVersionManifest.validated(for: repo)
            }

            let emptyNotesManifest = AdminUpdateManifest(
                version: "1.2",
                macVersion: "1.2",
                androidVersion: "1.2",
                title: "OK",
                notes: "   \n  ",
                releaseUrl: ""
            )
            #expect(throws: AdminManifestError.self) {
                _ = try emptyNotesManifest.validated(for: repo)
            }

            let longNotesManifest = AdminUpdateManifest(
                version: "1.2",
                macVersion: "1.2",
                androidVersion: "1.2",
                title: "OK",
                notes: String(repeating: "а", count: 501),
                releaseUrl: ""
            )
            #expect(throws: AdminManifestError.self) {
                _ = try longNotesManifest.validated(for: repo)
            }

            // Resilient decoding when optional manifest fields are omitted
            let partialJSON = Data(#"{"version":"1.9","notes":"Частичный JSON"}"#.utf8)
            let decodedPartial = try JSONDecoder().decode(AdminUpdateManifest.self, from: partialJSON)
            #expect(decodedPartial.version == "1.9")
            #expect(decodedPartial.macVersion == "1.9")
            #expect(decodedPartial.androidVersion == "1.9")
            #expect(decodedPartial.notes == "Частичный JSON")

            // Prompt signature detects edited text on same version
            let msgA = AppUpdateInfo(latestVersion: "1.5", currentVersion: "1.0", releaseURL: repo.releasesURL, title: "T", releaseNotes: "Text A")
            let msgB = AppUpdateInfo(latestVersion: "1.5", currentVersion: "1.0", releaseURL: repo.releasesURL, title: "T", releaseNotes: "Text B")
            #expect(msgA.promptSignature != msgB.promptSignature)
        }

        #expect(AppUpdateChecker.isVersion("v1.1", newerThan: "1.0") == true)
        #expect(AppUpdateChecker.isVersion("1.10.0", newerThan: "1.2.9") == true)
        #expect(AppUpdateChecker.isVersion("1.0", newerThan: "1.0.0") == false)
    }

    // MARK: - Socket Test Helpers

    private func connectLocalhost(port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard res == 0 else {
            throw FrameCodecError.socketError(String(cString: strerror(errno)))
        }
        return fd
    }

    private func makeHelloPacket(token: String) throws -> (
        payload: HelloPayload,
        privateKey: P256.KeyAgreement.PrivateKey,
        clientPub: Data,
        clientNonce: Data,
        psk: SymmetricKey
    ) {
        let privateKey = P256.KeyAgreement.PrivateKey()
        let clientPub = privateKey.publicKey.x963Representation
        let clientNonce = SecureChannel.randomBytes(count: 32)
        let psk = SecureChannel.derivePSK(from: token)
        let clientProof = SecureChannel.computeClientProof(psk: psk, clientPub: clientPub, clientNonce: clientNonce)
        let payload = HelloPayload(
            clientPub: clientPub.base64EncodedString(),
            clientNonce: clientNonce.base64EncodedString(),
            clientProof: clientProof.base64EncodedString()
        )
        return (payload, privateKey, clientPub, clientNonce, psk)
    }

    private func authenticateSession(
        fd: Int32,
        token: String,
        deviceName: String
    ) throws -> (cipher: SecureChannel.SessionCipher, authResult: AuthResultPayload) {
        let hello = try makeHelloPacket(token: token)
        try sendPlainJSON(fd: fd, type: .hello, json: hello.payload)

        let ackFrame = try readPlainFrame(fd: fd)
        #expect(ackFrame.type == .helloAck)
        let ack = try FrameCodec.decodeJSON(HelloAckPayload.self, from: ackFrame.payload)
        guard ack.ok,
              let serverPubB64 = ack.serverPub,
              let serverPubData = Data(base64Encoded: serverPubB64),
              let serverNonceB64 = ack.serverNonce,
              let serverNonce = Data(base64Encoded: serverNonceB64),
              let serverProofB64 = ack.serverProof,
              let serverProof = Data(base64Encoded: serverProofB64) else {
            throw FrameCodecError.socketError(ack.error ?? "HELLO_ACK failed")
        }

        let expectedServerProof = SecureChannel.computeServerProof(
            psk: hello.psk,
            clientPub: hello.clientPub,
            serverPub: serverPubData,
            clientNonce: hello.clientNonce,
            serverNonce: serverNonce
        )
        #expect(SecureChannel.constantTimeEquals(serverProof, expectedServerProof))

        let serverPublic = try P256.KeyAgreement.PublicKey(x963Representation: serverPubData)
        let sharedSecret = try hello.privateKey.sharedSecretFromKeyAgreement(with: serverPublic)
        let cipher = SecureChannel.SessionCipher(
            sharedSecret: sharedSecret,
            psk: hello.psk,
            clientNonce: hello.clientNonce,
            serverNonce: serverNonce,
            role: .client
        )

        try sendEncryptedJSON(fd: fd, cipher: cipher, type: .authIdentity, json: AuthIdentityPayload(deviceName: deviceName))
        let resultFrame = try readEncryptedFrame(fd: fd, cipher: cipher)
        #expect(resultFrame.type == .authResult)
        let result = try FrameCodec.decodeJSON(AuthResultPayload.self, from: resultFrame.payload)
        return (cipher, result)
    }

    private func sendEncryptedFile(
        fd: Int32,
        cipher: SecureChannel.SessionCipher,
        index: Int,
        relativePath: String,
        data: Data,
        isText: Bool
    ) throws {
        try sendEncryptedJSON(
            fd: fd,
            cipher: cipher,
            type: .fileStart,
            json: FileStartPayload(fileIndex: index, relativePath: relativePath, size: UInt64(data.count), isText: isText)
        )
        var offset = 0
        while offset < data.count {
            let end = min(offset + DroplyProtocol.chunkSize, data.count)
            try sendEncryptedRaw(fd: fd, cipher: cipher, type: .fileChunk, payload: data.subdata(in: offset..<end))
            offset = end
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try sendEncryptedJSON(fd: fd, cipher: cipher, type: .fileEnd, json: FileEndPayload(sha256: digest))
    }

    private func sendEncryptedJSON<T: Encodable>(
        fd: Int32,
        cipher: SecureChannel.SessionCipher,
        type: FrameType,
        json: T
    ) throws {
        let data = try JSONEncoder().encode(json)
        let packet = try cipher.sealPacket(type: type, plaintext: data)
        try writeAll(fd: fd, data: packet)
    }

    private func sendEncryptedRaw(
        fd: Int32,
        cipher: SecureChannel.SessionCipher,
        type: FrameType,
        payload: Data
    ) throws {
        let packet = try cipher.sealPacket(type: type, plaintext: payload)
        try writeAll(fd: fd, data: packet)
    }

    private func readEncryptedFrame(fd: Int32, cipher: SecureChannel.SessionCipher) throws -> RawFrame {
        let raw = try readPlainFrame(fd: fd)
        let decrypted = try cipher.openPayload(type: raw.type, sealedPayload: raw.payload)
        return RawFrame(type: raw.type, payload: decrypted)
    }

    private func sendPlainJSON<T: Encodable>(fd: Int32, type: FrameType, json: T) throws {
        let packet = try FrameCodec.encodeJSON(type: type, value: json)
        try writeAll(fd: fd, data: packet)
    }

    private func writeAll(fd: Int32, data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            while sent < data.count {
                let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 { throw FrameCodecError.socketError("send failed") }
                sent += n
            }
        }
    }

    private func readPlainFrame(fd: Int32) throws -> RawFrame {
        let header = try readExact(fd: fd, count: 5)
        guard let type = FrameType(rawValue: header[0]) else {
            throw FrameCodecError.invalidFrameType(header[0])
        }
        let len = header.withUnsafeBytes { ptr in
            UInt32(bigEndian: ptr.loadUnaligned(fromByteOffset: 1, as: UInt32.self))
        }
        let payload = try readExact(fd: fd, count: Int(len))
        return RawFrame(type: type, payload: payload)
    }

    private func readExact(fd: Int32, count: Int) throws -> Data {
        if count == 0 { return Data() }
        var data = Data(count: count)
        var total = 0
        try data.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            while total < count {
                let n = Darwin.recv(fd, base.advanced(by: total), count - total, 0)
                if n <= 0 { throw FrameCodecError.unexpectedEOF }
                total += n
            }
        }
        return data
    }
}

private final class ServerBox: @unchecked Sendable {
    var server: DroplyServer?
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ServerEvent] = []

    func append(_ event: ServerEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var completedFilesCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.filter {
            if case .fileCompleted = $0 { return true }
            return false
        }.count
    }

    var sawBatchCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return events.contains {
            if case .batchCompleted = $0 { return true }
            return false
        }
    }

    var lastConnectedName: String? {
        lock.lock()
        defer { lock.unlock() }
        for event in events.reversed() {
            if case .peerConnected(let name, _) = event { return name }
        }
        return nil
    }

    var isCurrentlyConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        var connected = false
        for event in events {
            switch event {
            case .peerConnected:
                connected = true
            case .peerDisconnected:
                connected = false
            default:
                break
            }
        }
        return connected
    }
}

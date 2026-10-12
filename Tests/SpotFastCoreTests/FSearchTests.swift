import XCTest
import Foundation
import Darwin
@testable import SpotFastCore

final class FSearchTests: XCTestCase {
    private func withServer(_ response: String, operation: (String) throws -> Void) throws {
        let root = FileManager.default.currentDirectoryPath + "/.build"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        var template = Array((root + "/fs.XXXXXX").utf8CString)
        guard let created = mkdtemp(&template) else { throw POSIXError(.EIO) }
        let directory = String(cString: created)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        chmod(directory, 0o700)
        let path = directory + "/s"
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        guard server >= 0 else { throw POSIXError(.EIO) }
        defer { close(server) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bound != 0 {
            let code = errno
            if code == EPERM || code == EACCES {
                throw XCTSkip("Managed environment denies Unix socket bind (errno \(code)); run outside this sandbox.")
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard chmod(path, 0o600) == 0, listen(server, 1) == 0 else { throw POSIXError(.EIO) }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { finished.signal() }
            var waiting = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 2000) > 0 else { return }
            let connection = accept(server, nil, nil)
            guard connection >= 0 else { return }
            defer { close(connection) }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            var noSignal: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
            var request = [UInt8](repeating: 0, count: 2048)
            _ = recv(connection, &request, request.count, 0)
            let bytes = Array(response.utf8)
            bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let sent = send(connection, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                    guard sent > 0 else { break }
                    offset += sent
                }
            }
        }
        defer { _ = finished.wait(timeout: .now() + 3) }
        try operation(path)
    }
    func testStatusRequiresHardenedProfileAndRestrictedMode() throws {
        let body = #"{"entries":14600000,"dirs":1600000,"index_bytes":289000000,"content_docs":0,"full_disk_access":false}"#
        try withServer("{\"ok\":true,\"profile\":\"spotfast-names-v1\",\"status\":\(body)}\n") { path in
            let status = try FSearchClient.status(socketPath: path)
            XCTAssertEqual(status.entries, 14600000)
            XCTAssertFalse(status.full_disk_access)
        }
        for (profile, state) in [("upstream", body), ("spotfast-names-v1", body.replacingOccurrences(of: "false", with: "true"))] {
            try withServer("{\"ok\":true,\"profile\":\"\(profile)\",\"status\":\(state)}\n") { path in
                XCTAssertThrowsError(try FSearchClient.status(socketPath: path))
            }
        }
    }
    func testValidReplyAndInvalidPaths() throws {
        try withServer("{\"ok\":true,\"profile\":\"spotfast-names-v1\",\"hits\":[{\"kind\":\"file\",\"path\":\"/tmp/résumé.txt\"},{\"kind\":\"file\",\"path\":\"relative.txt\"}]}\n") { path in
            let hits = try FSearchClient.search("résumé", socketPath: path)
            XCTAssertEqual(hits.map(\.path), ["/tmp/résumé.txt"])
        }
    }
    func testDecoderRejectsMalformedAndOversizedReplies() {
        for response in ["not-json", "{\"ok\":true}", "{\"ok\":true,\"profile\":\"spotfast-names-v1\",\"hits\":42}", "{\"ok\":false,\"error\":\"indexing\"}", String(repeating: "x", count: 1_048_577)] {
            XCTAssertThrowsError(try FSearchClient.decodeReply(Data(response.utf8)))
        }
    }
    func testDecoderRejectsUnpatchedDaemonProfile() {
        for payload: [String: Any] in [
            ["ok": true, "hits": []],
            ["ok": true, "profile": "upstream", "hits": []]
        ] {
            XCTAssertThrowsError(try FSearchClient.decodeReply(JSONSerialization.data(withJSONObject: payload)))
        }
    }
    func testDecoderLimitsAndSanitizesResults() throws {
        let hits = (0..<140).map { ["kind": "file", "path": "/tmp/\($0)"] }
        let payload = try JSONSerialization.data(withJSONObject: ["ok": true, "profile": "spotfast-names-v1", "hits": hits])
        XCTAssertEqual(try FSearchClient.decodeReply(payload).count, 100)
        let invalid = try JSONSerialization.data(withJSONObject: ["ok": true, "profile": "spotfast-names-v1", "hits": [
            ["kind": "file", "path": "relative"],
            ["kind": "file", "path": "/tmp/null\0name"],
            ["kind": "file", "path": "/tmp/résumé"]]])
        XCTAssertEqual(try FSearchClient.decodeReply(invalid).map(\.path), ["/tmp/résumé"])
    }
    func testBackendErrorAndInvalidJSON() throws {
        for response in ["{\"ok\":false,\"error\":\"indexing\"}\n", "not-json\n", "{\"ok\":true,\"profile\":\"spotfast-names-v1\",\"hits\":42}\n"] {
            try withServer(response) { path in
                XCTAssertThrowsError(try FSearchClient.search("test", socketPath: path))
            }
        }
    }
    func testOversizedReply() throws {
        try withServer(String(repeating: "x", count: 1_048_577) + "\n") { path in
            XCTAssertThrowsError(try FSearchClient.search("test", socketPath: path))
        }
    }
    func testPermissiveSocketRejected() throws {
        try withServer("{}\n") { path in
            XCTAssertEqual(chmod(path, 0o666), 0)
            XCTAssertThrowsError(try FSearchClient.search("test", socketPath: path)) { error in
                guard case FSearchClient.Failure.insecure = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }
}

import Foundation
import Darwin

public struct FSearchHit: Decodable, Sendable {
    public let path: String
    public let kind: String
}

public struct FSearchStatus: Decodable, Sendable {
    public let entries: Int
    public let dirs: Int
    public let index_bytes: Int
    public let full_disk_access: Bool
    public let content_docs: Int
}

/// Connects only to an existing, private, same-user daemon. Never starts one.
public enum FSearchClient {
    public enum Failure: Error, LocalizedError {
        case unavailable, insecure, timeout, malformed, backend(String)
        public var errorDescription: String? {
            switch self {
            case .unavailable: return "FSearch is unavailable; using Apple metadata."
            case .insecure: return "FSearch requires a same-user socket in a private (0700) directory."
            case .timeout: return "FSearch timed out; using Apple metadata."
            case .malformed: return "FSearch returned an invalid or oversized response."
            case .backend(let reason): return "FSearch: \(reason.prefix(200))"
            }
        }
    }
    private struct Reply: Decodable { let ok: Bool; let hits: [FSearchHit]?; let error: String?; let profile: String? }
    public static func search(_ query: String, socketPath: String) throws -> [FSearchHit] {
        guard query.utf8.count <= 1024 else { throw Failure.malformed }
        guard !["grep:", "regex:", "sym:", "content:", "symbol:", "git:"].contains(where: { query.contains($0) }) else {
            throw Failure.backend("Content operators are disabled; Apple metadata remains available.")
        }
        return try decodeReply(request(["q": query, "limit": 100], socketPath: socketPath))
    }
    public static func probe(socketPath: String) throws {
        let data = try request(["op": "ping"], socketPath: socketPath)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["ok"] as? Bool == true, result["profile"] as? String == "spotfast-names-v1" else { throw Failure.malformed }
    }
    public static func status(socketPath: String) throws -> FSearchStatus {
        struct StatusReply: Decodable { let ok: Bool; let profile: String; let status: FSearchStatus }
        let data = try request(["op": "status"], socketPath: socketPath)
        let reply = try JSONDecoder().decode(StatusReply.self, from: data)
        guard reply.ok, reply.profile == "spotfast-names-v1",
              reply.status.entries >= 0, reply.status.dirs >= 0, reply.status.index_bytes >= 0,
              reply.status.content_docs == 0, !reply.status.full_disk_access else { throw Failure.malformed }
        return reply.status
    }
    private static func request(_ payload: [String: Any], socketPath: String) throws -> Data {
        // Reject symlinked directory components and anything accessible to another user.
        let directory = (socketPath as NSString).deletingLastPathComponent
        var current = URL(fileURLWithPath: directory)
        while current.path != "/" {
            var info = stat()
            guard lstat(current.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR else { throw Failure.insecure }
            if current.path == directory {
                guard info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Failure.insecure }
            } else {
                guard info.st_mode & 0o022 == 0, info.st_uid == getuid() || info.st_uid == 0 else { throw Failure.insecure }
            }
            current.deleteLastPathComponent()
        }
        var info = stat()
        guard lstat(socketPath, &info) == 0 else { throw Failure.unavailable }
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK,
              info.st_mode & 0o077 == 0 else { throw Failure.insecure }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw Failure.unavailable }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let deadline = Date().addingTimeInterval(0.8)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if status != 0 {
            guard errno == EINPROGRESS else { throw Failure.unavailable }
            try ready(fd, events: Int16(POLLOUT), deadline: deadline)
            var code: Int32 = 0
            var length = socklen_t(MemoryLayout.size(ofValue: code))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &length) == 0, code == 0 else { throw Failure.unavailable }
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw Failure.insecure }
        var request = try JSONSerialization.data(withJSONObject: payload)
        request.append(10)
        var offset = 0
        while offset < request.count {
            try ready(fd, events: Int16(POLLOUT), deadline: deadline)
            let sent = request.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: offset), request.count - offset, 0) }
            if sent < 0, errno == EAGAIN || errno == EINTR { continue }
            guard sent > 0 else { throw Failure.unavailable }
            offset += sent
        }
        shutdown(fd, SHUT_WR)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count <= 1_048_576 {
            try ready(fd, events: Int16(POLLIN), deadline: deadline)
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { throw Failure.malformed }
            data.append(contentsOf: buffer.prefix(count))
            if let newline = data.firstIndex(of: 10) {
                guard newline <= 1_048_576 else { throw Failure.malformed }
                return Data(data[..<newline])
            }
        }
        throw Failure.malformed
    }
    static func decodeReply(_ data: Data) throws -> [FSearchHit] {
        guard data.count <= 1_048_576 else { throw Failure.malformed }
        let reply: Reply
        do { reply = try JSONDecoder().decode(Reply.self, from: data) }
        catch { throw Failure.malformed }
        guard reply.ok else { throw Failure.backend(reply.error ?? "Unknown error") }
        guard reply.profile == "spotfast-names-v1", let hits = reply.hits else { throw Failure.malformed }
        return Array(hits.prefix(100)).filter {
            $0.path.hasPrefix("/") && !$0.path.utf8.contains(0) && $0.path.utf8.count < 4096
        }
    }
    private static func ready(_ fd: Int32, events: Int16, deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw Failure.timeout }
            var p = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&p, 1, Int32(ceil(remaining * 1000)))
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw Failure.timeout }
            guard p.revents & events != 0 else { throw Failure.unavailable }
            return
        }
    }
}

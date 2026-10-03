import Darwin
import Foundation

public enum PresenceSocketError: Error, Equatable, CustomStringConvertible {
    case pathTooLong(String)
    case alreadyRunning(String)
    case systemCall(String, Int32)

    public var description: String {
        switch self {
        case .pathTooLong(let path):
            return "Socket path is longer than the 103 bytes a Unix socket allows: \(path)"
        case .alreadyRunning(let path):
            return "A presence process is already serving \(path)."
        case .systemCall(let name, let code):
            return "\(name) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Thin wrappers over the BSD socket calls both ends need.
enum UnixSocket {
    static let maximumPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    static func makeAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= maximumPathLength else {
            throw PresenceSocketError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw PresenceSocketError.systemCall("socket", errno)
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    /// Connects a blocking stream socket. Returns the fd, or the errno on failure.
    static func connect(path: String) -> Result<Int32, PresenceSocketError> {
        do {
            var address = try makeAddress(path)
            let fd = try makeSocket()
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                let code = errno
                close(fd)
                return .failure(.systemCall("connect", code))
            }
            return .success(fd)
        } catch let error as PresenceSocketError {
            return .failure(error)
        } catch {
            return .failure(.systemCall("connect", EINVAL))
        }
    }

    static func bind(_ fd: Int32, path: String) throws {
        var address = try makeAddress(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw PresenceSocketError.systemCall("bind", errno)
        }
    }

    static func setNonBlocking(_ fd: Int32, _ enabled: Bool) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, enabled ? flags | O_NONBLOCK : flags & ~O_NONBLOCK)
    }

    static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else {
            return nil
        }
        return pid
    }

    /// Writes all bytes, waiting out a full send buffer for up to `timeout`.
    static func writeAll(_ fd: Int32, _ data: Data, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else {
                return true
            }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR {
                    continue
                }
                guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                    return false
                }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else {
                    return false
                }
                var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&poller, 1, Int32(min(remaining, 1) * 1000))
            }
            return true
        }
    }
}

/// Splits a byte stream into newline-terminated lines.
struct LineBuffer {
    static let maximumLineLength = 1 << 20

    private var pending = Data()

    /// Appends bytes and returns the complete lines, or nil if a line grew
    /// past the limit and the stream should be dropped.
    mutating func append(_ bytes: Data) -> [Data]? {
        pending.append(bytes)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty {
                lines.append(Data(line))
            }
            pending.removeSubrange(pending.startIndex...newline)
        }
        if pending.count > Self.maximumLineLength {
            return nil
        }
        return lines
    }
}

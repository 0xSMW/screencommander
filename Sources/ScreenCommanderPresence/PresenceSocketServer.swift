import Darwin
import Foundation

/// Serves the presence protocol on a Unix domain socket. Needs no AppKit, so
/// tests run it in-process against a `PresenceCore` with a headless driver.
///
/// Single-instance: a `flock` on `<socket>.lock` is held for the server's
/// lifetime. A crashed predecessor's lock is released by the kernel, so a
/// socket file left behind is known to be stale and gets replaced. If the lock
/// is held, or the socket answers a connect, `start()` throws `alreadyRunning`.
public final class PresenceSocketServer: @unchecked Sendable {
    public let socketPath: String

    private let core: PresenceCore
    private let queue = DispatchQueue(label: "screencommander.presence.socket")
    private var listenFD: Int32 = -1
    private var lockFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [PresenceConnectionID: Connection] = [:]
    private var nextConnectionID: PresenceConnectionID = 1

    public init(socketPath: String, core: PresenceCore) {
        self.socketPath = socketPath
        self.core = core
    }

    deinit {
        stop()
    }

    public var connectionCount: Int {
        queue.sync { connections.count }
    }

    public func start() throws {
        let directory = (socketPath as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        _ = try UnixSocket.makeAddress(socketPath)

        let lockPath = socketPath + ".lock"
        let lock = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else {
            throw PresenceSocketError.systemCall("open \(lockPath)", errno)
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw PresenceSocketError.alreadyRunning(socketPath)
        }

        do {
            try replaceStaleSocket()
            let fd = try UnixSocket.makeSocket()
            do {
                try UnixSocket.bind(fd, path: socketPath)
                chmod(socketPath, 0o600)
                guard listen(fd, 32) == 0 else {
                    throw PresenceSocketError.systemCall("listen", errno)
                }
            } catch {
                close(fd)
                throw error
            }
            UnixSocket.setNonBlocking(fd, true)
            listenFD = fd
            lockFD = lock
        } catch {
            close(lock)
            throw error
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPending()
        }
        acceptSource = source
        source.resume()
    }

    public func stop() {
        let wasRunning: Bool = queue.sync {
            guard listenFD >= 0 else {
                return false
            }
            acceptSource?.cancel()
            acceptSource = nil
            close(listenFD)
            listenFD = -1
            for connection in connections.values {
                connection.close()
            }
            connections.removeAll()
            return true
        }
        guard wasRunning else {
            return
        }
        unlink(socketPath)
        if lockFD >= 0 {
            close(lockFD)
            lockFD = -1
        }
    }

    // MARK: Private

    private func replaceStaleSocket() throws {
        var info = stat()
        guard lstat(socketPath, &info) == 0 else {
            return
        }
        if case .success(let fd) = UnixSocket.connect(path: socketPath) {
            close(fd)
            throw PresenceSocketError.alreadyRunning(socketPath)
        }
        guard unlink(socketPath) == 0 || errno == ENOENT else {
            throw PresenceSocketError.systemCall("unlink \(socketPath)", errno)
        }
    }

    /// Runs on `queue`.
    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else {
                return
            }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            UnixSocket.setNonBlocking(fd, true)

            let id = nextConnectionID
            nextConnectionID += 1
            let connection = Connection(id: id, fd: fd)
            connections[id] = connection
            core.connectionOpened(id, peerPID: UnixSocket.peerPID(fd))

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self, weak connection] in
                guard let self, let connection else {
                    return
                }
                self.readAvailable(from: connection)
            }
            source.setCancelHandler {
                connection.closeDescriptor()
            }
            connection.readSource = source
            source.resume()
        }
    }

    /// Runs on `queue`.
    private func readAvailable(from connection: Connection) {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(connection.fd, &buffer, buffer.count)
            if count > 0 {
                guard let lines = connection.lines.append(Data(buffer[0..<count])) else {
                    drop(connection)
                    return
                }
                for line in lines {
                    dispatch(line, from: connection)
                }
                continue
            }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return
            }
            if count < 0 && errno == EINTR {
                continue
            }
            drop(connection)
            return
        }
    }

    private func dispatch(_ line: Data, from connection: Connection) {
        let envelope: PresenceRequestEnvelope
        do {
            envelope = try JSONDecoder().decode(PresenceRequestEnvelope.self, from: line)
        } catch {
            let id = PresenceResponse.peekID(in: line) ?? 0
            let method = Self.methodName(in: line)
            let code: PresenceErrorCode = method != nil && PresenceMethod(rawValue: method!) == nil ? .unknownMethod : .invalidRequest
            connection.send(.failure(id: id, code, "Could not decode request: \(error)"))
            return
        }
        core.handle(envelope, connection: connection.id) { [weak connection] response in
            connection?.send(response)
        }
    }

    private static func methodName(in line: Data) -> String? {
        struct MethodOnly: Decodable { let method: String }
        return try? JSONDecoder().decode(MethodOnly.self, from: line).method
    }

    /// Runs on `queue`.
    private func drop(_ connection: Connection) {
        guard connections.removeValue(forKey: connection.id) != nil else {
            return
        }
        connection.close()
        core.connectionClosed(connection.id)
    }

    private final class Connection {
        let id: PresenceConnectionID
        let fd: Int32
        var lines = LineBuffer()
        var readSource: DispatchSourceRead?

        private let writeLock = NSLock()
        private var closed = false
        private var descriptorClosed = false

        init(id: PresenceConnectionID, fd: Int32) {
            self.id = id
            self.fd = fd
        }

        func send(_ response: PresenceResponse) {
            guard let data = try? response.encodeLine() else {
                return
            }
            writeLock.lock()
            defer { writeLock.unlock() }
            guard !closed else {
                return
            }
            if !UnixSocket.writeAll(fd, data, timeout: 2) {
                // The reader notices the broken pipe and drops the connection.
                shutdown(fd, SHUT_RDWR)
            }
        }

        /// Stops reading and closes the descriptor once the read source is cancelled.
        func close() {
            writeLock.lock()
            let alreadyClosed = closed
            closed = true
            writeLock.unlock()
            guard !alreadyClosed else {
                return
            }
            if let readSource {
                readSource.cancel()
                self.readSource = nil
            } else {
                closeDescriptor()
            }
        }

        func closeDescriptor() {
            writeLock.lock()
            defer { writeLock.unlock() }
            guard !descriptorClosed else {
                return
            }
            descriptorClosed = true
            Darwin.close(fd)
        }
    }
}

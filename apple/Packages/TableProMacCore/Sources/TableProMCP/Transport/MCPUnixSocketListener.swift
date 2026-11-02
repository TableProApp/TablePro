import Darwin
import Foundation
import os

public enum MCPUnixSocketListenerError: Error, Equatable, LocalizedError {
    case pathTooLong(String)
    case occupied(String)
    case systemCall(String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path):
            return "The socket path is longer than \(MCPSocketLocation.maxPathBytes) bytes: \(path)"
        case .occupied(let path):
            return "Something that is not a socket already exists at \(path)"
        case .systemCall(let name, let code):
            return "\(name) failed: \(String(cString: strerror(code)))"
        }
    }
}

// NWListener cannot listen on a Unix socket. The peer uid check backs up the 0700 folder.
public final class MCPUnixSocketListener: @unchecked Sendable {
    public typealias ConnectionHandler = @Sendable (MCPUnixSocketConnection) -> Void

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.UnixSocketListener")

    public let path: String
    private let allowedPeerUid: uid_t
    private let onConnection: ConnectionHandler
    private let queue = DispatchQueue(label: "com.TablePro.MCP.UnixSocketListener")
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var boundFile: (device: dev_t, inode: ino_t)?

    public init(path: String, allowedPeerUid: uid_t = getuid(), onConnection: @escaping ConnectionHandler) {
        self.path = path
        self.allowedPeerUid = allowedPeerUid
        self.onConnection = onConnection
    }

    public func start() throws {
        guard MCPSocketLocation.fits(path) else {
            throw MCPUnixSocketListenerError.pathTooLong(path)
        }
        try removeStaleSocket()

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw MCPUnixSocketListenerError.systemCall("socket", errno: errno)
        }
        do {
            try configureListening(descriptor)
        } catch {
            close(descriptor)
            throw error
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { @Sendable [weak self] in
            self?.acceptPending(on: descriptor)
        }
        source.setCancelHandler { @Sendable in
            close(descriptor)
        }
        lock.withLock { self.source = source }
        source.resume()
    }

    public func stop() {
        let taken = lock.withLock { () -> (DispatchSourceRead?, (device: dev_t, inode: ino_t)?) in
            defer {
                source = nil
                boundFile = nil
            }
            return (source, boundFile)
        }
        taken.0?.cancel()
        guard let bound = taken.1 else { return }
        // Another TablePro that replaced the file owns it now, so only the file this bound goes.
        var info = stat()
        guard lstat(path, &info) == 0, info.st_dev == bound.device, info.st_ino == bound.inode else { return }
        unlink(path)
    }

    public static func peerUid(of descriptor: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0 else { return nil }
        return uid
    }

    private func configureListening(_ descriptor: Int32) throws {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }
        guard bound == 0 else {
            throw MCPUnixSocketListenerError.systemCall("bind", errno: errno)
        }
        chmod(path, 0o600)

        var info = stat()
        if lstat(path, &info) == 0 {
            let identity = (device: info.st_dev, inode: info.st_ino)
            lock.withLock { boundFile = identity }
        }

        guard listen(descriptor, SOMAXCONN) == 0 else {
            let code = errno
            stop()
            throw MCPUnixSocketListenerError.systemCall("listen", errno: code)
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let code = errno
            stop()
            throw MCPUnixSocketListenerError.systemCall("fcntl", errno: code)
        }
    }

    // A crashed TablePro leaves its socket file behind, and bind fails while it exists.
    private func removeStaleSocket() throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK else {
            throw MCPUnixSocketListenerError.occupied(path)
        }
        unlink(path)
    }

    private func acceptPending(on listening: Int32) {
        while true {
            let descriptor = accept(listening, nil, nil)
            guard descriptor >= 0 else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            var noSigPipe: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            guard let peer = Self.peerUid(of: descriptor), peer == allowedPeerUid else {
                Self.logger.error("Refused a Unix socket peer that is not the current user")
                close(descriptor)
                continue
            }
            onConnection(MCPUnixSocketConnection(descriptor: descriptor))
        }
    }
}

#if os(macOS)
import Foundation
import Darwin

/// Local endpoint for agents on this Mac: a Unix domain socket in the user's data folder.
///
/// The `axolotl` command-line tool bridges MCP clients (Claude Code, Claude Desktop, Cursor, …)
/// to it over stdio. Only processes running as the same user can connect: the socket is mode
/// 0600 inside a user-only directory, and each connection's peer uid is checked.
final class AgentSocketServer {
    static func socketPath(dataDirectory: URL) -> String {
        let path = dataDirectory.appendingPathComponent("agent.sock").path
        // sockaddr_un.sun_path holds 104 bytes; fall back to a per-user temporary path.
        if path.utf8.count < 100 { return path }
        return FileManager.default.temporaryDirectory.appendingPathComponent("axolotl-\(getuid()).sock").path
    }

    let path: String
    private weak var model: AppModel?
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.nearbycoder.axolotl.agent-socket")
    private var clients: [Int32: Client] = [:]

    init(path: String, model: AppModel) {
        self.path = path
        self.model = model
    }

    deinit { stop() }

    func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        // Create the socket file with owner-only permissions from the start.
        let oldMask = umask(0o077)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        umask(oldMask)
        guard bound == 0 else { let e = errno; close(fd); throw POSIXError(.init(rawValue: e) ?? .EIO) }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { let e = errno; close(fd); throw POSIXError(.init(rawValue: e) ?? .EIO) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        queue.sync {
            for (_, c) in clients { c.close() }
            clients.removeAll()
        }
        unlink(path)
    }

    private func acceptConnections() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { Darwin.close(fd); continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let client = Client(fd: fd, queue: queue) { [weak self] fd in
                self?.clients.removeValue(forKey: fd)
                self?.publishCount()
            }
            clients[fd] = client
            publishCount()
            Task { @MainActor [weak self] in
                guard let model = self?.model else { return }
                client.attach(session: MCPSession(toolbox: AgentToolbox(model: model)))
            }
        }
    }

    private func publishCount() {
        let count = clients.count
        Task { @MainActor [weak self] in self?.model?.agentConnectionsChanged(count) }
    }

    /// One connected client: reads newline-delimited JSON-RPC, answers in order.
    final class Client {
        let fd: Int32
        private let queue: DispatchQueue
        private var source: DispatchSourceRead?
        private var buffer = Data()
        private var closed = false
        private let onClose: (Int32) -> Void
        private var continuation: AsyncStream<Data>.Continuation?

        init(fd: Int32, queue: DispatchQueue, onClose: @escaping (Int32) -> Void) {
            self.fd = fd
            self.queue = queue
            self.onClose = onClose
        }

        @MainActor
        func attach(session: MCPSession) {
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            self.continuation = continuation
            // Requests are answered strictly in order, one at a time. When the client stops sending,
            // every request already received is still answered before the connection closes.
            Task { @MainActor in
                for await line in stream {
                    if let response = await session.handle(line) { self.send(response) }
                }
                self.queue.async { self.close() }
            }
            queue.async { self.startReading() }
        }

        private func startReading() {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.resume()
            self.source = source
        }

        private func readAvailable() {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
            guard n > 0 else {
                // End of input: stop reading, then finish answering what was already received.
                source?.cancel()
                source = nil
                continuation?.finish()
                return
            }
            buffer.append(chunk, count: n)
            // A single message may not exceed 64 MB (base64 attachments are the largest).
            guard buffer.count < 64 * 1024 * 1024 else { close(); return }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { continuation?.yield(Data(line)) }
            }
        }

        func send(_ data: Data) {
            queue.async {
                guard !self.closed else { return }
                data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let n = write(self.fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                        if n > 0 { offset += n; continue }
                        if n < 0 && (errno == EAGAIN || errno == EINTR) { usleep(1000); continue }
                        self.close()
                        return
                    }
                }
            }
        }

        func close() {
            guard !closed else { return }
            closed = true
            continuation?.finish()
            source?.cancel()
            source = nil
            Darwin.close(fd)
            onClose(fd)
        }
    }
}
#endif

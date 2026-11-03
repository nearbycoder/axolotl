import Foundation
import Network

public struct PeerInfo: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var lastSync: Date?
}

/// Peer-to-peer sync between devices on the same local network, discovered over Bonjour.
/// Only devices holding the same sync code can talk: every frame is sealed with the vault key.
@MainActor
final class LANSync {
    static let serviceType = "_axolotl._tcp"

    struct Message: Codable {
        var t: String
        var id: String?
        var name: String?
        var vector: [String: String]?
        var rows: [SyncRow]?
        var hash: String?
    }

    /// Sealed frame payloads start with a type byte.
    private enum FrameType: UInt8 {
        case message = 0   // JSON `Message`
        case blob = 1      // 64-char hex hash followed by the raw bytes
    }

    final class Peer {
        let connection: NWConnection
        let outbound: Bool
        var deviceId: String?
        var name = "Device"
        var vector: [String: String]?
        var lastSync: Date?
        var requestedBlobs = Set<String>()
        init(connection: NWConnection, outbound: Bool) {
            self.connection = connection
            self.outbound = outbound
        }
    }

    let replica: Replica
    let keys: VaultKeys
    let deviceName: String
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var dialing = Set<String>()
    var onPeersChanged: (([PeerInfo]) -> Void)?
    var onSynced: (() -> Void)?

    init(replica: Replica, keys: VaultKeys, deviceName: String) {
        self.replica = replica
        self.keys = keys
        self.deviceName = deviceName
    }

    func start() {
        guard listener == nil else { return }
        let txt = NWTXTRecord(["v": keys.lanHint, "id": replica.deviceId])
        do {
            let l = try NWListener(using: .tcp)
            l.service = NWListener.Service(name: "\(deviceName) (\(replica.deviceId.prefix(4)))", type: Self.serviceType, domain: nil, txtRecord: txt)
            l.newConnectionHandler = { [weak self] conn in
                MainActor.assumeIsolated { self?.attach(conn, outbound: false) }
            }
            l.stateUpdateHandler = { [weak self] state in
                if case .failed = state { MainActor.assumeIsolated { self?.restartSoon() } }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            restartSoon()
            return
        }

        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.handle(results) }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        for p in peers.values { p.connection.cancel() }
        peers.removeAll()
        dialing.removeAll()
        publishPeers()
    }

    private func restartSoon() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case .bonjour(let txt) = result.metadata,
                  txt["v"] == keys.lanHint,
                  let peerId = txt["id"], peerId != replica.deviceId,
                  // Only the device with the smaller id dials, so each pair has one connection.
                  replica.deviceId < peerId,
                  !dialing.contains(peerId),
                  !peers.values.contains(where: { $0.deviceId == peerId }) else { continue }
            dialing.insert(peerId)
            attach(NWConnection(to: result.endpoint, using: .tcp), outbound: true, expected: peerId)
        }
    }

    private func attach(_ connection: NWConnection, outbound: Bool, expected: String? = nil) {
        let peer = Peer(connection: connection, outbound: outbound)
        let key = ObjectIdentifier(peer)
        peers[key] = peer
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.send(Message(t: "hello", id: self.replica.deviceId, name: self.deviceName, vector: self.replica.vector), to: peer)
                    self.receive(peer)
                case .failed, .cancelled:
                    if let expected { self.dialing.remove(expected) }
                    self.peers.removeValue(forKey: key)
                    self.publishPeers()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func drop(_ peer: Peer) {
        peer.connection.cancel()
    }

    // MARK: Framing

    private func send(_ message: Message, to peer: Peer) {
        guard let plain = try? JSON.encoder.encode(message) else { return }
        sendFrame(.message, plain, to: peer)
    }

    /// Blobs travel as raw bytes rather than base64 inside JSON, which saves a third of the
    /// bandwidth and two in-memory copies.
    private func sendBlob(_ hash: String, _ data: Data, to peer: Peer) {
        var plain = Data(hash.utf8)
        plain.append(data)
        sendFrame(.blob, plain, to: peer)
    }

    private func sendFrame(_ type: FrameType, _ plain: Data, to peer: Peer) {
        var payload = Data([type.rawValue])
        payload.append(plain)
        guard let sealed = try? keys.seal(payload) else { return }
        var frame = Data()
        var length = UInt32(sealed.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(sealed)
        peer.connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func receive(_ peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard error == nil, !complete, let header, header.count == 4 else { return self.drop(peer) }
                let length = header.reduce(0) { ($0 << 8) | Int($1) }
                // Until a peer proves it holds the vault key with a valid hello, it may not make us buffer much.
                let limit = peer.deviceId == nil ? 64 * 1024 : 256 * 1024 * 1024
                guard length > 0, length <= limit else { return self.drop(peer) }
                peer.connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                    MainActor.assumeIsolated {
                        guard error == nil, let body, body.count == length,
                              let plain = try? self.keys.open(body), let type = plain.first else { return self.drop(peer) }
                        let payload = plain.dropFirst()
                        switch FrameType(rawValue: type) {
                        case .message:
                            guard let message = try? JSON.decoder.decode(Message.self, from: payload) else { return self.drop(peer) }
                            self.handle(message, from: peer)
                        case .blob:
                            guard peer.deviceId != nil, payload.count > 64 else { return self.drop(peer) }
                            let hash = String(decoding: payload.prefix(64), as: UTF8.self)
                            if (try? self.replica.putBlob(Data(payload.dropFirst(64)), expectedHash: hash)) != nil { self.onSynced?() }
                        case nil:
                            return self.drop(peer)
                        }
                        self.receive(peer)
                    }
                }
            }
        }
    }

    // MARK: Protocol

    private func handle(_ message: Message, from peer: Peer) {
        guard peer.deviceId != nil || message.t == "hello" else { return drop(peer) }
        switch message.t {
        case "hello":
            guard let id = message.id, id != replica.deviceId else { return drop(peer) }
            if peers.values.contains(where: { $0 !== peer && $0.deviceId == id }) {
                // Duplicate connection: keep the one dialed by the smaller id.
                let iDialed = replica.deviceId < id
                if peer.outbound != iDialed { return drop(peer) }
            }
            peer.deviceId = id
            peer.name = message.name ?? "Device"
            peer.vector = message.vector ?? [:]
            sendMissing(to: peer)
            publishPeers()
        case "rows":
            let rows = message.rows ?? []
            replica.apply(rows, markDirty: true)
            if var v = peer.vector {
                for r in rows where (v[r.origin] ?? "") < r.hlc { v[r.origin] = r.hlc }
                peer.vector = v
            }
            peer.lastSync = Date()
            requestBlobs(from: peer)
            publishPeers()
            onSynced?()
        case "blobReq":
            if let hash = message.hash, Replica.isValidBlobHash(hash) {
                if let data = replica.blob(hash) {
                    sendBlob(hash, data, to: peer)
                } else {
                    send(Message(t: "blobMissing", hash: hash), to: peer)
                }
            }
        default:
            break
        }
    }

    private func sendMissing(to peer: Peer) {
        guard let vector = peer.vector else { return }
        let rows = replica.rows(after: vector)
        guard !rows.isEmpty else { return }
        replica.markSent(rows)
        var v = vector
        for chunk in stride(from: 0, to: rows.count, by: 300).map({ Array(rows[$0..<min($0 + 300, rows.count)]) }) {
            send(Message(t: "rows", rows: chunk), to: peer)
            for r in chunk where (v[r.origin] ?? "") < r.hlc { v[r.origin] = r.hlc }
        }
        peer.vector = v
        peer.lastSync = Date()
    }

    private func requestBlobs(from peer: Peer) {
        for hash in replica.missingBlobs where !peer.requestedBlobs.contains(hash) {
            peer.requestedBlobs.insert(hash)
            send(Message(t: "blobReq", hash: hash), to: peer)
        }
    }

    /// Pushes newly written local rows to every connected peer.
    func broadcast() {
        for peer in peers.values where peer.deviceId != nil { sendMissing(to: peer) }
        publishPeers()
    }

    private func publishPeers() {
        let list = peers.values.compactMap { p in p.deviceId.map { PeerInfo(id: $0, name: p.name, lastSync: p.lastSync) } }
        var unique: [String: PeerInfo] = [:]
        for p in list { unique[p.id] = p }
        onPeersChanged?(unique.values.sorted { $0.name < $1.name })
    }
}

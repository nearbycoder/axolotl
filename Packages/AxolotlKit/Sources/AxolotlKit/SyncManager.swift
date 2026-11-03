import Foundation
import Observation

/// Drives sync for a replica over the LAN transport and, when configured, the sync server.
@MainActor
@Observable
public final class SyncManager {
    public enum ServerState: Equatable {
        case notConfigured
        case connecting
        case connected
        case error(String)
    }

    public private(set) var keys: VaultKeys?
    public private(set) var serverURL: URL?
    public private(set) var lanEnabled = true
    public private(set) var serverState: ServerState = .notConfigured
    public private(set) var peers: [PeerInfo] = []
    public private(set) var lastSync: Date?
    public private(set) var isSyncing = false
    public private(set) var pendingChanges = 0

    @ObservationIgnored let replica: Replica
    @ObservationIgnored let deviceName: String
    @ObservationIgnored private var lan: LANSync?
    @ObservationIgnored private var pullTask: Task<Void, Never>?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var lanBroadcast: Task<Void, Never>?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var pushAgain = false

    public var isConfigured: Bool { keys != nil }

    public init(replica: Replica, deviceName: String) {
        self.replica = replica
        self.deviceName = deviceName
        if let code = replica.kv("sync.code") { keys = VaultKeys(syncCode: code) }
        serverURL = replica.kv("sync.server").flatMap(URL.init(string:))
        lanEnabled = replica.kv("sync.lan") != "off"
        pendingChanges = replica.dirtyCount
    }

    // MARK: Configuration

    /// Starts a new vault on this device and returns its sync code.
    @discardableResult
    public func createVault() -> String {
        let code = VaultKeys.generateCode()
        join(code: code)
        return code
    }

    @discardableResult
    public func join(code: String) -> Bool {
        guard let k = VaultKeys(syncCode: code) else { return false }
        stopTransports()
        keys = k
        replica.setKV("sync.code", k.code)
        replica.setKV("sync.cursor", nil)
        replica.markAllDirty()
        startTransports()
        return true
    }

    public func leaveVault() {
        stopTransports()
        keys = nil
        replica.setKV("sync.code", nil)
        replica.setKV("sync.cursor", nil)
        serverState = .notConfigured
        peers = []
    }

    public func setServer(_ string: String?) {
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var url: URL?
        if !trimmed.isEmpty {
            url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")
        }
        guard url != serverURL else { return }
        stopServer()
        serverURL = url
        replica.setKV("sync.server", url?.absoluteString)
        replica.setKV("sync.cursor", nil)
        replica.markAllDirty()
        if active { startServer() }
    }

    public func setLANEnabled(_ on: Bool) {
        lanEnabled = on
        replica.setKV("sync.lan", on ? "on" : "off")
        if on, active { startLAN() } else { lan?.stop(); lan = nil; peers = [] }
    }

    // MARK: Lifecycle

    /// Call when the app becomes active.
    public func activate() {
        guard !active else { return }
        active = true
        startTransports()
    }

    /// Call when the app moves to the background.
    public func deactivate() {
        active = false
        stopTransports()
    }

    /// Call after every replica change.
    public func replicaChanged(_ change: ReplicaChange) {
        if change.hasLocalRows {
            pendingChanges = replica.dirtyCount
            scheduleLANBroadcast()
            schedulePush()
        }
        if change.isRemote { lastSync = Date() }
    }

    public func syncNow() {
        lan?.broadcast()
        schedulePush(delay: 0)
        if serverURL != nil, keys != nil, active {
            pullTask?.cancel()
            startServer()
        }
    }

    private func startTransports() {
        guard active, keys != nil else { return }
        if lanEnabled { startLAN() }
        startServer()
    }

    private func stopTransports() {
        lan?.stop()
        lan = nil
        stopServer()
    }

    private func startLAN() {
        guard let keys, lan == nil else { return }
        let l = LANSync(replica: replica, keys: keys, deviceName: deviceName)
        l.onPeersChanged = { [weak self] in self?.peers = $0 }
        l.onSynced = { [weak self] in self?.lastSync = Date() }
        l.start()
        lan = l
    }

    private func scheduleLANBroadcast() {
        guard lan != nil else { return }
        lanBroadcast?.cancel()
        lanBroadcast = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.lan?.broadcast()
        }
    }

    // MARK: Server

    private var client: ServerClient? {
        guard let keys, let serverURL else { return nil }
        return ServerClient(baseURL: serverURL, keys: keys)
    }

    private func stopServer() {
        pullTask?.cancel(); pullTask = nil
        pushTask?.cancel(); pushTask = nil
        serverState = serverURL == nil ? .notConfigured : serverState
    }

    private func startServer() {
        guard let client, active else {
            serverState = .notConfigured
            return
        }
        serverState = .connecting
        pullTask = Task { [weak self] in
            var backoff: Double = 2
            var wait = 0
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.push(client)
                    try await self.pull(client, wait: wait)
                    try await self.transferBlobs(client)
                    self.serverState = .connected
                    backoff = 2
                    wait = 25
                } catch is CancellationError {
                    return
                } catch let error as URLError where error.code == .cancelled {
                    return
                } catch {
                    self.serverState = .error(error.localizedDescription)
                    try? await Task.sleep(for: .seconds(backoff))
                    backoff = min(backoff * 2, 60)
                    wait = 0
                }
            }
        }
    }

    private func schedulePush(delay: Double = 1.2) {
        guard let client, active else { return }
        if pushTask != nil { pushAgain = true; return }
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            repeat {
                self.pushAgain = false
                do {
                    try await self.push(client)
                    try await self.transferBlobs(client)
                } catch {
                    if !(error is CancellationError) { self.serverState = .error(error.localizedDescription) }
                    break
                }
            } while self.pushAgain
            self.pushTask = nil
        }
    }

    private func push(_ client: ServerClient) async throws {
        while true {
            let batch = replica.takeDirtyRows(limit: 300)
            if batch.isEmpty { break }
            isSyncing = true
            defer { isSyncing = false }
            _ = try await client.push(batch.map(\.row))
            replica.markClean(batch)
            pendingChanges = replica.dirtyCount
            lastSync = Date()
        }
    }

    private func pull(_ client: ServerClient, wait: Int) async throws {
        var cursor = Int(replica.kv("sync.cursor") ?? "0") ?? 0
        var currentWait = wait
        while true {
            let result = try await client.pull(since: cursor, wait: currentWait)
            try Task.checkCancellation()
            if !result.rows.isEmpty {
                replica.apply(result.rows, markDirty: false)
                lastSync = Date()
            }
            cursor = result.cursor
            replica.setKV("sync.cursor", String(cursor))
            if !result.more { break }
            currentWait = 0
        }
        // Merges may have produced new local revisions.
        try await push(client)
    }

    private func transferBlobs(_ client: ServerClient) async throws {
        for hash in replica.blobsToUpload {
            if try await !client.hasBlob(hash), let data = replica.blob(hash) {
                try await client.uploadBlob(hash, data: data)
            }
            replica.markBlobUploaded(hash)
        }
        for hash in replica.missingBlobs {
            if let data = try await client.downloadBlob(hash) {
                _ = try? replica.putBlob(data, expectedHash: hash)
                replica.markBlobUploaded(hash)
                lastSync = Date()
            }
        }
    }
}

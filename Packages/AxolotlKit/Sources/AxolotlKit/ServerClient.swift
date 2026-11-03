import Foundation

/// Client for the Axolotl sync relay (see `server/`). Everything except the vault id, the auth
/// token, an opaque per-field key and the HLC is end-to-end encrypted with the vault key.
public struct ServerClient: Sendable {
    public let baseURL: URL
    public let keys: VaultKeys
    let session: URLSession

    public init(baseURL: URL, keys: VaultKeys, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.keys = keys
        self.session = session
    }

    public struct ServerError: LocalizedError {
        public var status: Int
        public var message: String
        public var errorDescription: String? { "Sync server error \(status): \(message)" }
    }

    struct PushItem: Codable { var k: String; var h: String; var d: String }
    struct PushBody: Codable { var changes: [PushItem] }
    struct PushResponse: Codable { var accepted: Int; var cursor: Int }
    struct PullItem: Codable { var s: Int; var k: String?; var h: String?; var d: String }
    struct PullResponse: Codable { var changes: [PullItem]; var cursor: Int; var more: Bool }

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: baseURL.appendingPathComponent("v1/vaults/\(keys.vaultId)/\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }

    private func request(_ url: URL, method: String, body: Data? = nil, contentType: String = "application/json", timeout: TimeInterval = 30) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("Bearer \(keys.authToken)", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = body
            r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ServerError(status: 0, message: "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw ServerError(status: http.statusCode, message: String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    public func health() async throws {
        let (data, response) = try await session.data(for: request(baseURL.appendingPathComponent("v1/health"), method: "GET", timeout: 10))
        try check(response, data)
    }

    public func push(_ rows: [SyncRow]) async throws -> Int {
        let items = try rows.map { row in
            PushItem(k: keys.rowKey(row), h: row.hlc, d: try keys.seal(JSON.encoder.encode(row)).base64EncodedString())
        }
        let body = try JSON.encoder.encode(PushBody(changes: items))
        let (data, response) = try await session.data(for: request(url("push"), method: "POST", body: body))
        try check(response, data)
        return try JSON.decoder.decode(PushResponse.self, from: data).cursor
    }

    public func pull(since cursor: Int, wait: Int = 0, limit: Int = 500) async throws -> (rows: [SyncRow], cursor: Int, more: Bool) {
        let u = url("pull", query: [.init(name: "since", value: String(cursor)), .init(name: "limit", value: String(limit)), .init(name: "wait", value: String(wait))])
        let (data, response) = try await session.data(for: request(u, method: "GET", timeout: TimeInterval(wait + 20)))
        try check(response, data)
        let decoded = try JSON.decoder.decode(PullResponse.self, from: data)
        let rows: [SyncRow] = decoded.changes.compactMap { item in
            guard let sealed = Data(base64Encoded: item.d), let plain = try? keys.open(sealed),
                  let row = try? JSON.decoder.decode(SyncRow.self, from: plain) else { return nil }
            // The key and timestamp the relay stores must match the sealed row; otherwise a
            // compromised relay could replay an old version of a field under a newer timestamp.
            if let k = item.k, k != keys.rowKey(row) { return nil }
            if let h = item.h, h != row.hlc { return nil }
            return row
        }
        return (rows, decoded.cursor, decoded.more)
    }

    public func hasBlob(_ hash: String) async throws -> Bool {
        let (data, response) = try await session.data(for: request(url("blobs/\(keys.blobKey(hash))"), method: "HEAD"))
        if (response as? HTTPURLResponse)?.statusCode == 404 { return false }
        try check(response, data)
        return true
    }

    public func uploadBlob(_ hash: String, data plain: Data) async throws {
        let sealed = try keys.seal(plain)
        let (data, response) = try await session.data(for: request(url("blobs/\(keys.blobKey(hash))"), method: "PUT", body: sealed,
                                                                      contentType: "application/octet-stream", timeout: 300))
        try check(response, data)
    }

    public func downloadBlob(_ hash: String) async throws -> Data? {
        let (data, response) = try await session.data(for: request(url("blobs/\(keys.blobKey(hash))"), method: "GET", timeout: 300))
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try check(response, data)
        return try keys.open(data)
    }
}

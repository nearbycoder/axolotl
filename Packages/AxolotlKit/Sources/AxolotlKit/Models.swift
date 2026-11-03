import Foundation

/// One field of one entity, stamped with the HLC of the write that produced it.
/// This is the unit the sync engine stores, compacts and exchanges.
public struct SyncRow: Codable, Hashable, Sendable {
    public var entity: String
    public var id: String
    public var field: String
    /// JSON-encoded value.
    public var value: String
    public var hlc: String
    public var origin: String

    public init(entity: String, id: String, field: String, value: String, hlc: String, origin: String) {
        self.entity = entity
        self.id = id
        self.field = field
        self.value = value
        self.hlc = hlc
        self.origin = origin
    }

    enum CodingKeys: String, CodingKey {
        case entity = "e", id = "i", field = "f", value = "v", hlc = "h", origin = "o"
    }
}

public enum Entity {
    public static let note = "note"
    public static let tag = "tag"
    public static let attachment = "attachment"
    public static let config = "config"
}

/// Value of a note's `body` field: the text and the lineage of revisions it descends from.
public struct BodyValue: Codable, Hashable, Sendable {
    public var t: String
    /// Ancestor revision ids, newest first. Bounded by `Replica.maxAncestors`.
    public var a: [String]
}

public struct Heading: Hashable, Sendable, Identifiable {
    public var level: Int
    public var text: String
    /// UTF-16 offset of the heading line in the body.
    public var location: Int
    public var id: Int { location }
}

public struct NoteMeta: Hashable, Sendable {
    public var title: String = ""
    public var preview: String = ""
    public var tags: [String] = []
    public var wikiLinks: [String] = []
    public var openTodos = 0
    public var doneTodos = 0
    public var hasCode = false
    public var imageIds: [String] = []
    public var fileIds: [String] = []
    public var headings: [Heading] = []

    public init() {}
}

public struct Note: Identifiable, Hashable, Sendable {
    public let id: String
    public var body: String = ""
    public var bodyRev: String = ""
    public var ancestors: [String] = []
    public var created: Date = .distantPast
    public var modified: Date = .distantPast
    public var pinned = false
    public var archived = false
    public var trashedAt: Date?
    public var lockedTitle: String?
    public var conflictOf: String?
    public var deleted = false
    public var meta = NoteMeta()

    public init(id: String) { self.id = id }

    public var isEncrypted: Bool { NoteCrypto.isEncrypted(body) }
    public var isTrashed: Bool { trashedAt != nil }
    public var title: String {
        if isEncrypted { return lockedTitle?.isEmpty == false ? lockedTitle! : "Locked Note" }
        return meta.title
    }
    public var isUntitled: Bool { !isEncrypted && meta.title.isEmpty }
}

public struct TagMeta: Hashable, Sendable {
    public var path: String
    public var icon: String?
    public var pinned = false
    public init(path: String) { self.path = path }
}

public struct Attachment: Identifiable, Hashable, Sendable {
    public let id: String
    public var noteId: String = ""
    public var name: String = ""
    public var mime: String = "application/octet-stream"
    public var hash: String = ""
    public var size: Int = 0
    public var ocr: String = ""
    public var deleted = false
    public init(id: String) { self.id = id }
    public var isImage: Bool { mime.hasPrefix("image/") }
}

public extension Date {
    var secondsValue: String { String(timeIntervalSince1970) }
}

enum JSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    static let decoder = JSONDecoder()

    static func encode<T: Encodable>(_ value: T) -> String {
        (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "null"
    }

    static func decode<T: Decodable>(_ type: T.Type, _ string: String) -> T? {
        try? decoder.decode(T.self, from: Data(string.utf8))
    }
}

import Foundation

/// A hybrid logical clock timestamp.
///
/// Encoded as a fixed-width string (`<millis:13>-<counter:4 hex>-<node>`) so that plain
/// string comparison orders timestamps the same way the tuple `(millis, counter, node)` does.
/// Every record in the sync engine is stamped with one of these.
public struct HLC: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let millis: Int64
    public let counter: Int
    public let node: String

    public init(millis: Int64, counter: Int, node: String) {
        self.millis = millis
        self.counter = counter
        self.node = node
    }

    public init?(_ string: String) {
        let parts = string.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let ms = Int64(parts[0]), let c = Int(parts[1], radix: 16) else { return nil }
        self.init(millis: ms, counter: c, node: String(parts[2]))
    }

    public var description: String {
        let ms = String(millis)
        let c = String(counter, radix: 16)
        return String(repeating: "0", count: max(0, 13 - ms.count)) + ms + "-"
            + String(repeating: "0", count: max(0, 4 - c.count)) + c + "-" + node
    }

    public var date: Date { Date(timeIntervalSince1970: Double(millis) / 1000) }

    public static func < (a: HLC, b: HLC) -> Bool {
        if a.millis != b.millis { return a.millis < b.millis }
        if a.counter != b.counter { return a.counter < b.counter }
        return a.node < b.node
    }
}

/// Monotonic hybrid logical clock for one replica.
public final class HybridClock: @unchecked Sendable {
    public let node: String
    private var last: HLC
    private let lock = NSLock()
    private let wallClock: () -> Int64

    public init(node: String, last: String? = nil, wallClock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.node = node
        self.wallClock = wallClock
        self.last = last.flatMap(HLC.init) ?? HLC(millis: 0, counter: 0, node: node)
    }

    public var current: String { lock.withLock { last.description } }

    /// A fresh timestamp strictly greater than every timestamp issued or observed so far.
    public func now() -> String {
        lock.withLock {
            let wall = wallClock()
            if wall > last.millis {
                last = HLC(millis: wall, counter: 0, node: node)
            } else if last.counter >= 0xFFFF {
                last = HLC(millis: last.millis + 1, counter: 0, node: node)
            } else {
                last = HLC(millis: last.millis, counter: last.counter + 1, node: node)
            }
            return last.description
        }
    }

    /// Fold a remote timestamp in so that subsequent local timestamps sort after it.
    public func observe(_ remote: String) {
        guard let r = HLC(remote) else { return }
        lock.withLock {
            if r.millis > last.millis || (r.millis == last.millis && r.counter > last.counter) {
                last = HLC(millis: r.millis, counter: r.counter, node: node)
            }
        }
    }
}

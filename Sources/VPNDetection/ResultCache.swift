/// How the per-client answer cache behaves.
public struct CacheOptions: Sendable, Hashable {
    /// Maximum number of addresses held. Default 10000.
    public var maxEntries: Int
    /// How long an answer stays fresh. Default 1 hour.
    public var ttl: Duration

    public init(maxEntries: Int = 10_000, ttl: Duration = .seconds(3600)) {
        self.maxEntries = maxEntries
        self.ttl = ttl
    }
}

/// A least-recently-used cache with a time to live, keyed by address.
///
/// One instance per client, never global: two clients with different keys are on
/// different plans and entitled to different fields, so a shared cache would
/// serve one of them the other's shape. An actor rather than a lock because the
/// cache is the ONLY mutable state in the library, and isolating it is what lets
/// ``VPNDetectionClient`` stay a plain `Sendable` struct whose methods run on the
/// caller's executor.
///
/// Hand-rolled rather than taken from a dependency: nothing in the Swift package
/// ecosystem is the blessed LRU (NSCache has no TTL and no deterministic
/// eviction, and is unreliable on Linux), and an intrusive list over a
/// dictionary is a few dozen lines for O(1) reads, writes and evictions.
actor ResultCache {
    private let maxEntries: Int
    private let ttl: Duration
    private var entries: [String: Node] = [:]
    private var head: Node?
    private var tail: Node?

    init(_ options: CacheOptions) {
        precondition(options.maxEntries > 0, "cache maxEntries must be positive")
        precondition(options.ttl > .zero, "cache ttl must be positive")
        self.maxEntries = options.maxEntries
        self.ttl = options.ttl
    }

    func get(_ ip: String) -> LookupResult? {
        guard let node = entries[ip] else {
            return nil
        }
        guard node.expires > ContinuousClock.now else {
            remove(node)
            return nil
        }
        promote(node)
        return node.result
    }

    func set(_ ip: String, _ result: LookupResult) {
        if let existing = entries[ip] {
            existing.result = result
            existing.expires = ContinuousClock.now.advanced(by: ttl)
            promote(existing)
            return
        }
        let node = Node(ip: ip, result: result, expires: ContinuousClock.now.advanced(by: ttl))
        entries[ip] = node
        prepend(node)
        if entries.count > maxEntries, let oldest = tail {
            remove(oldest)
        }
    }

    private func promote(_ node: Node) {
        guard head !== node else {
            return
        }
        unlink(node)
        prepend(node)
    }

    private func prepend(_ node: Node) {
        node.previous = nil
        node.next = head
        head?.previous = node
        head = node
        if tail == nil {
            tail = node
        }
    }

    private func remove(_ node: Node) {
        unlink(node)
        entries[node.ip] = nil
    }

    private func unlink(_ node: Node) {
        node.previous?.next = node.next
        node.next?.previous = node.previous
        if head === node {
            head = node.next
        }
        if tail === node {
            tail = node.previous
        }
        node.previous = nil
        node.next = nil
    }

    // Reference semantics so recency can be reordered without rehashing, and
    // actor isolation keeps every node inside this instance.
    private final class Node {
        let ip: String
        var result: LookupResult
        var expires: ContinuousClock.Instant
        var previous: Node?
        var next: Node?

        init(ip: String, result: LookupResult, expires: ContinuousClock.Instant) {
            self.ip = ip
            self.result = result
            self.expires = expires
        }
    }
}

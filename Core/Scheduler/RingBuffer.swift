/// Fixed-size history. Appending never allocates after initialization.
public struct RingBuffer<Element: Sendable>: Sendable {
    private var storage: [Element]
    private var head = 0
    public private(set) var count = 0

    public let capacity: Int

    public init(capacity: Int, filler: Element) {
        self.capacity = max(capacity, 1)
        storage = Array(repeating: filler, count: self.capacity)
    }

    public mutating func append(_ element: Element) {
        storage[head] = element
        head = (head + 1) % capacity
        count = Swift.min(count + 1, capacity)
    }

    /// Calls `body` with each element, oldest first, without creating an array.
    public func forEach(_ body: (Element) -> Void) {
        let start = (head - count + capacity) % capacity
        for offset in 0..<count {
            body(storage[(start + offset) % capacity])
        }
    }

    public var last: Element? {
        count == 0 ? nil : storage[(head - 1 + capacity) % capacity]
    }

    public var elements: [Element] {
        var result: [Element] = []
        result.reserveCapacity(count)
        forEach { result.append($0) }
        return result
    }
}

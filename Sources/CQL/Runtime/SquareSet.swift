/// A set of chessboard squares stored as a 64-bit mask.
///
/// Bit `i` represents the square with index `i`, where `index = rank * 8 + file`
/// with `a1 == 0`, `h1 == 7`, `a8 == 56` and `h8 == 63` (the same layout used by
/// FischerCore's `Square`).
public struct SquareSet: Hashable, Sendable, Sequence, CustomStringConvertible {
    public var rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public init() { self.rawValue = 0 }
    public init(index: Int) { self.rawValue = 1 << UInt64(index) }
    public init(file: Int, rank: Int) { self.rawValue = 1 << UInt64(rank * 8 + file) }

    public init<S: Sequence>(indices: S) where S.Element == Int {
        var raw: UInt64 = 0
        for index in indices { raw |= 1 << UInt64(index) }
        self.rawValue = raw
    }

    public static let empty = SquareSet(rawValue: 0)
    public static let all = SquareSet(rawValue: ~0)
    public static let light = SquareSet(rawValue: 0x55AA_55AA_55AA_55AA)
    public static let dark = SquareSet(rawValue: 0xAA55_AA55_AA55_AA55)

    public static func file(_ file: Int) -> SquareSet { SquareSet(rawValue: 0x0101_0101_0101_0101 << UInt64(file)) }
    public static func rank(_ rank: Int) -> SquareSet { SquareSet(rawValue: 0xFF << UInt64(rank * 8)) }

    /// Rectangle of squares covering the inclusive file and rank ranges.
    public static func rectangle(files: ClosedRange<Int>, ranks: ClosedRange<Int>) -> SquareSet {
        var result = SquareSet()
        for rank in ranks { for file in files { result.insert(rank * 8 + file) } }
        return result
    }

    public var isEmpty: Bool { rawValue == 0 }
    public var count: Int { rawValue.nonzeroBitCount }
    public var first: Int? { rawValue == 0 ? nil : rawValue.trailingZeroBitCount }
    /// The single square of this set, if it has exactly one element.
    public var single: Int? { count == 1 ? first : nil }

    public func contains(_ index: Int) -> Bool { rawValue & (1 << UInt64(index)) != 0 }
    public mutating func insert(_ index: Int) { rawValue |= 1 << UInt64(index) }
    public mutating func remove(_ index: Int) { rawValue &= ~(1 << UInt64(index)) }

    public static func | (lhs: SquareSet, rhs: SquareSet) -> SquareSet { SquareSet(rawValue: lhs.rawValue | rhs.rawValue) }
    public static func & (lhs: SquareSet, rhs: SquareSet) -> SquareSet { SquareSet(rawValue: lhs.rawValue & rhs.rawValue) }
    public static prefix func ~ (set: SquareSet) -> SquareSet { SquareSet(rawValue: ~set.rawValue) }
    public static func |= (lhs: inout SquareSet, rhs: SquareSet) { lhs.rawValue |= rhs.rawValue }
    public static func &= (lhs: inout SquareSet, rhs: SquareSet) { lhs.rawValue &= rhs.rawValue }

    public func isSubset(of other: SquareSet) -> Bool { rawValue & ~other.rawValue == 0 }

    public struct Iterator: IteratorProtocol {
        var remaining: UInt64
        public mutating func next() -> Int? {
            guard remaining != 0 else { return nil }
            let index = remaining.trailingZeroBitCount
            remaining &= remaining - 1
            return index
        }
    }

    public func makeIterator() -> Iterator { Iterator(remaining: rawValue) }

    public var description: String {
        let names = map { SquareName.name(of: $0) }
        return names.count == 1 ? names[0] : "[" + names.joined(separator: ",") + "]"
    }
}

/// Helpers for converting between square indices and algebraic names.
public enum SquareName {
    public static func name(of index: Int) -> String {
        let file = Character(UnicodeScalar(UInt8(97 + index % 8)))
        return "\(file)\(index / 8 + 1)"
    }

    public static func index(of name: String) -> Int? {
        let scalars = Array(name.unicodeScalars)
        guard scalars.count == 2,
              (97...104).contains(scalars[0].value),
              (49...56).contains(scalars[1].value) else { return nil }
        return Int(scalars[1].value - 49) * 8 + Int(scalars[0].value - 97)
    }
}

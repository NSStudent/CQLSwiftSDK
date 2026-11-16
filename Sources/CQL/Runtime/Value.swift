/// The value computed by a CQL filter.
///
/// A filter evaluation returns `Value?`: `nil` means the filter did not
/// match the current position. A set filter always returns a ``set`` value
/// (possibly empty); it *matches* only when the set is non-empty.
public enum Value: Hashable, Sendable, CustomStringConvertible {
    /// A logical filter matched (it has no value).
    case matched
    case set(SquareSet)
    case number(Int)
    case string(String)
    case position(PositionRef)
    /// A piece variable value: the identity of a piece.
    case piece(PieceIdentity)

    public var matches: Bool {
        if case .set(let set) = self { return !set.isEmpty }
        return true
    }

    public var description: String {
        switch self {
        case .matched: "true"
        case .set(let set): set.description
        case .number(let number): String(number)
        case .string(let string): string
        case .position(let position): "position \(position.node.id)"
        case .piece(let piece): "piece#\(piece.id)"
        }
    }
}

/// A reference to a node in the current game tree, compared by identity.
public struct PositionRef: Hashable, Sendable {
    public let node: PositionNode
    public init(_ node: PositionNode) { self.node = node }
    public static func == (lhs: PositionRef, rhs: PositionRef) -> Bool { lhs.node === rhs.node }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(node)) }
}

/// The identity of a piece, stable across the moves of a game.
public struct PieceIdentity: Hashable, Sendable {
    public let id: Int
    public init(id: Int) { self.id = id }
}

/// The static type of a filter.
public enum ValueType: String, Hashable, Sendable {
    case logical, set, number, string, position, piece, dictionary, unknown
}

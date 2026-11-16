extension Filter {
    /// The direct child filters (arguments, operands, bodies, ⊢ constituents…).
    public var subfilters: [Filter] {
        var result: [Filter] = []
        _ = try? mapChildren { (child) throws(CQLError) -> Filter in
            result.append(child)
            return child
        }
        return result
    }

    /// Whether this filter or any filter nested in it satisfies `predicate`.
    public func contains(where predicate: (Filter) -> Bool) -> Bool {
        if predicate(self) { return true }
        return subfilters.contains { $0.contains(where: predicate) }
    }

    /// Returns a copy with `transform` applied to every direct child filter.
    func mapChildren(_ transform: (Filter) throws(CQLError) -> Filter) throws(CQLError) -> Filter {
        func opt(_ filter: Filter?) throws(CQLError) -> Filter? {
            guard let filter else { return nil }
            return try transform(filter)
        }
        func all(_ filters: [Filter]) throws(CQLError) -> [Filter] {
            var result: [Filter] = []
            for filter in filters { result.append(try transform(filter)) }
            return result
        }
        func dash(_ value: DashFilter) throws(CQLError) -> DashFilter {
            var copy = value
            copy.left = try opt(value.left)
            copy.right = try opt(value.right)
            copy.promotionFilter = try opt(value.promotionFilter)
            if let targets = value.targets { copy.targets = try all(targets) }
            return copy
        }

        switch self {
        case .number, .string, .pieceDesignator, .variable, .keyword, .captureGroup, .captureGroupIndex,
             .isBound, .dictionaryDeclaration, .tagValue, .elo, .result, .fenMatch, .originalComment:
            return self
        case .compound(let filters): return .compound(try all(filters))
        case .not(let f): return .not(try transform(f))
        case .negate(let f): return .negate(try transform(f))
        case .complement(let f): return .complement(try transform(f))
        case .cardinality(let f): return .cardinality(try transform(f))
        case .binary(let op, let l, let r): return .binary(op, try transform(l), try transform(r))
        case .attackChain(let operands, let reversed): return .attackChain(try all(operands), reversed: reversed)
        case .at(let p, let f): return .at(try transform(p), try transform(f))
        case .subscript(let t, let a, let b, let isSlice): return .subscript(try transform(t), try opt(a), try opt(b), isSlice: isSlice)
        case .prefix(let name, let f): return .prefix(name, try transform(f))
        case .call(let name, let args): return .call(name, try all(args))
        case .direction(let name, let range, let f): return .direction(name, range: range, try transform(f))
        case .ray(let direction, let sets, let xray): return .ray(direction: direction, try all(sets), xray: xray)
        case .pin(let from, let through, let to, let role):
            return .pin(from: try opt(from), through: try opt(through), to: try opt(to), role: role)
        case .assign(let name, let op, let f): return .assign(name, op, try transform(f))
        case .pieceAssign(let name, let f): return .pieceAssign(name, try transform(f))
        case .subscriptAssign(let name, let key, let end, let isSlice, let value):
            return .subscriptAssign(name, key: try transform(key), end: try opt(end), isSlice: isSlice, value: try transform(value))
        case .persistent(let quiet, let name, let op, let f): return .persistent(quiet: quiet, name, op, try transform(f))
        case .atomic(let name, let op, let f): return .atomic(name, op, try transform(f))
        case .path(var path):
            path.focus = try opt(path.focus)
            path.maximize = try opt(path.maximize)
            func constituents(_ items: [PathConstituent]) throws(CQLError) -> [PathConstituent] {
                var result: [PathConstituent] = []
                for item in items {
                    switch item {
                    case .move(let d): result.append(.move(try dash(d)))
                    case .filter(let f): result.append(.filter(try transform(f)))
                    case .chain(let inner): result.append(.chain(try constituents(inner)))
                    case .repetition(let inner, let minimum, let maximum):
                        result.append(.repetition(try constituents(inner), minimum: minimum, maximum: maximum))
                    }
                }
                return result
            }
            path.constituents = try constituents(path.constituents)
            return .path(path)
        case .unbind(let name, let key): return .unbind(name, key: try opt(key))
        case .iterate(let isPiece, let isAll, let variable, let domain, let body):
            return .iterate(isPiece: isPiece, all: isAll, variable: variable, domain: try transform(domain), body: try transform(body))
        case .iterateDictionary(let variable, let dictionary, let body):
            return .iterateDictionary(variable: variable, dictionary: dictionary, body: try transform(body))
        case .ifThen(let c, let t, let e): return .ifThen(try transform(c), try transform(t), try opt(e))
        case .loop(let f): return .loop(try transform(f))
        case .whileLoop(let c, let b): return .whileLoop(try transform(c), try transform(b))
        case .whileRegex(let target, let pattern, let body):
            return .whileRegex(target: try transform(target), pattern: pattern, body: try transform(body))
        case .functionCall(let name, let args): return .functionCall(name, try all(args))
        case .assert(let f): return .assert(try transform(f))
        case .dash(let d, let source): return .dash(try dash(d), source: source)
        case .countMoves(let d, let source): return .countMoves(try dash(d), source: source)
        case .find(let quiet, let mode, let backward, let f): return .find(quiet: quiet, mode: mode, backward: backward, try transform(f))
        case .echo(let s, let t, let includeSelf, let quiet, let f):
            return .echo(source: s, target: t, includeSelf: includeSelf, quiet: quiet, try transform(f))
        case .consecutiveMoves(let quiet, let range, let a, let b):
            return .consecutiveMoves(quiet: quiet, range: range, try transform(a), try transform(b))
        case .child(let f): return .child(try opt(f))
        case .position(let f): return .position(try transform(f))
        case .transform(let kind, let count, let f): return .transform(kind, count: count, try transform(f))
        case .transformOrbit(let elements, let count): return .transformOrbit(try all(elements), count: count)
        case .notransform(let f): return .notransform(try transform(f))
        case .comment(let args): return .comment(try all(args))
        case .message(let quiet, let args): return .message(quiet: quiet, try all(args))
        case .sort(let isMin, let quiet, let doc, let f): return .sort(min: isMin, quiet: quiet, documentation: doc, try transform(f))
        case .setTag(let a, let b): return .setTag(try transform(a), try transform(b))
        }
    }

    /// Renames variables (used for function-call macro expansion).
    func renamingVariables(_ names: [String: String]) -> Filter {
        func rename(_ name: String) -> String { names[name] ?? name }
        let renamed: Filter
        switch self {
        case .variable(let name): return .variable(rename(name))
        case .assign(let name, let op, let f): renamed = .assign(rename(name), op, f)
        case .pieceAssign(let name, let f): renamed = .pieceAssign(rename(name), f)
        case .subscriptAssign(let name, let key, let end, let isSlice, let value):
            renamed = .subscriptAssign(rename(name), key: key, end: end, isSlice: isSlice, value: value)
        case .persistent(let quiet, let name, let op, let f): renamed = .persistent(quiet: quiet, rename(name), op, f)
        case .atomic(let name, let op, let f): renamed = .atomic(rename(name), op, f)
        case .unbind(let name, let key): renamed = .unbind(rename(name), key: key)
        case .isBound(let name, let negated): return .isBound(rename(name), negated: negated)
        case .iterate(let isPiece, let isAll, let variable, let domain, let body):
            renamed = .iterate(isPiece: isPiece, all: isAll, variable: rename(variable), domain: domain, body: body)
        case .iterateDictionary(let variable, let dictionary, let body):
            renamed = .iterateDictionary(variable: rename(variable), dictionary: dictionary, body: body)
        case .echo(let s, let t, let includeSelf, let quiet, let f):
            renamed = .echo(source: rename(s), target: rename(t), includeSelf: includeSelf, quiet: quiet, f)
        default: renamed = self
        }
        return (try? renamed.mapChildren { $0.renamingVariables(names) }) ?? renamed
    }
}

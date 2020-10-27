// MARK: Subject to change prior to 1.0.0 release
// MARK: -

internal struct ZeroSerializer {
    // MARK: - Internal Only
    
    init(
        ast: [Syntax],
        context data: [String: ZeroData],
        tags: [String: ZeroTag] = defaultTags,
        userInfo: [AnyHashable: Any] = [:]
    ) {
        self.ast = ast
        self.offset = 0
        self.buffer = String()
        self.data = data
        self.tags = tags
        self.userInfo = userInfo
    }
    
    mutating func serialize() throws -> String {
        self.offset = 0
        while let next = self.peek() {
            self.pop()
            try self.serialize(next)
        }
        return self.buffer
    }
    
    // MARK: - Private Only
    
    private let ast: [Syntax]
    private var offset: Int
    private var buffer: String
    private var data: [String: ZeroData]
    private let tags: [String: ZeroTag]
    private let userInfo: [AnyHashable: Any]

    private mutating func serialize(_ syntax: Syntax) throws {
        switch syntax {
            case .raw(let byteBuffer): buffer.append(byteBuffer)
            case .custom(let custom):  try serialize(custom)
            case .conditional(let c):  try serialize(c)
            case .loop(let loop):      try serialize(loop)
            case .expression(let exp): try serialize(expression: exp)
            case .import, .extend, .export:
                throw "\(syntax) should have been resolved BEFORE serialization"
        }
    }

    private mutating func serialize(expression: [ParameterDeclaration]) throws {
        let resolved = try self.resolve(parameters: [.expression(expression)])
        guard resolved.count == 1, let zeroData = resolved.first else {
            throw "expressions should resolve to single value"
        }
        try? zeroData.serialize(buffer: &self.buffer)
    }

    private mutating func serialize(body: [Syntax]) throws {
        try body.forEach { try serialize($0) }
    }

    private mutating func serialize(_ conditional: Syntax.Conditional) throws {
        evaluate:
        for block in conditional.chain {
            let evaluated = try resolveAtomic(block.condition.expression())
            guard (evaluated.bool ?? false) || (!evaluated.isNil && evaluated.celf != .bool) else { continue }
            try serialize(body: block.body)
            break evaluate
        }
    }

    private mutating func serialize(_ tag: Syntax.CustomTagDeclaration) throws {
        let sub = try ZeroContext(
            parameters: self.resolve(parameters: tag.params),
            data: data,
            body: tag.body,
            userInfo: self.userInfo
        )
        let zeroData = try self.tags[tag.name]?.render(sub) ?? ZeroData.trueNil
        try? zeroData.serialize(buffer: &self.buffer)
    }

 

    private mutating func serialize(_ loop: Syntax.Loop) throws {
        let finalData: [String: ZeroData]
        let pathComponents = loop.array.split(separator: ".")

        if pathComponents.count > 1 {
            finalData = try pathComponents[0..<(pathComponents.count - 1)].enumerated()
                .reduce(data) { (innerData, pathContext) -> [String: ZeroData] in
                    let key = String(pathContext.element)

                    guard let nextData = innerData[key]?.dictionary else {
                        let currentPath = pathComponents[0...pathContext.offset].joined(separator: ".")
                        throw "expected dictionary at key: \(currentPath)"
                    }

                    return nextData
                }
        } else {
            finalData = data
        }

        guard let array = finalData[String(pathComponents.last!)]?.array else {
            throw "expected array at key: \(loop.array)"
        }

        for (idx, item) in array.enumerated() {
            var innerContext = self.data

            innerContext["isFirst"] = .bool(idx == array.startIndex)
            innerContext["isLast"] = .bool(idx == array.index(before: array.endIndex))
            innerContext["index"] = .int(idx)
            innerContext[loop.item] = item

            var serializer = ZeroSerializer(
                ast: loop.body,
                context: innerContext,
                tags: self.tags,
                userInfo: self.userInfo
            )
            let loopBody = try serializer.serialize()
            buffer.append(loopBody)
        }
    }

    private func resolve(parameters: [ParameterDeclaration]) throws -> [ZeroData] {
        let resolver = ParameterResolver(
            params: parameters,
            data: data,
            tags: self.tags,
            userInfo: userInfo
        )
        return try resolver.resolve().map { $0.result }
    }
    
    // Directive resolver for a [ParameterDeclaration] where only one parameter is allowed that must resolve to a single value
    private func resolveAtomic(_ parameters: [ParameterDeclaration]) throws -> ZeroData {
        guard parameters.count == 1 else {
            if parameters.isEmpty {
                throw ZeroError(.unknownError("Parameter statement can't be empty"))
            } else {
                throw ZeroError(.unknownError("Parameter statement must hold a single value"))
            }
        }
        return try resolve(parameters: parameters).first ?? .trueNil
    }

    private func peek() -> Syntax? {
        guard self.offset < self.ast.count else {
            return nil
        }
        return self.ast[self.offset]
    }

    private mutating func pop() { self.offset += 1 }
}

import TheScore

@_spi(ButtonHeistTooling) public struct FenceParameter<Value: Sendable>: Sendable {
    public let key: String
    public let defaultValue: Value?

    internal let spec: FenceParameterSpec
    private let convertValue: @Sendable (HeistValue) throws -> Value?
    private let encodeValue: @Sendable (Value) -> HeistValue

    internal init(
        key: String,
        spec: FenceParameterSpec,
        defaultValue: Value? = nil,
        convertValue: @escaping @Sendable (HeistValue) throws -> Value?,
        encodeValue: @escaping @Sendable (Value) -> HeistValue
    ) {
        precondition(spec.key == key, "FenceParameter key must match its schema")
        guard case .scalar = spec.schema else {
            preconditionFailure("FenceParameter requires a scalar schema")
        }
        precondition(
            defaultValue.map(encodeValue) == spec.defaultValue,
            "FenceParameter default must match its schema"
        )
        self.key = key
        self.spec = spec
        self.defaultValue = defaultValue
        self.convertValue = convertValue
        self.encodeValue = encodeValue
    }

    public var allowedRawValues: [String]? {
        spec.enumValues
    }

    internal var expectedTypeDescription: String {
        spec.expectedTypeDescription
    }

    public func heistValue(for value: Value) -> HeistValue {
        encodeValue(value)
    }

    internal func decode(_ value: HeistValue, field: String) throws -> Value {
        try spec.validateScalar(value, field: field)
        guard let decoded = try convertValue(value) else {
            preconditionFailure("FenceParameter converter disagrees with schema for \(key)")
        }
        return decoded
    }
}

@_spi(ButtonHeistTooling) public enum MCPExposure: Sendable, Equatable {
    case directTool
    case notExposed
}

@_spi(ButtonHeistTooling) public struct MCPToolAnnotationSpec: Sendable, Equatable {
    public let readOnlyHint: Bool?
    public let idempotentHint: Bool?

    public init(
        readOnlyHint: Bool? = nil,
        idempotentHint: Bool? = nil
    ) {
        self.readOnlyHint = readOnlyHint
        self.idempotentHint = idempotentHint
    }
}

@_spi(ButtonHeistTooling) public enum CLIExposure: Sendable, Equatable {
    case directCommand
    case notExposed
}

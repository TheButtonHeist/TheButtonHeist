import Foundation
import ThePlans
import TheScore

extension TheFence {

    struct ExpectationPayload: Sendable {
        let expectation: AccessibilityPredicate?
        let timeout: WaitTimeout?

        init(expectation: AccessibilityPredicate?, timeout: WaitTimeout?) {
            self.expectation = expectation
            self.timeout = timeout
        }

        init(arguments: CommandArgumentEnvelope) throws {
            let timeout = try arguments.value(FenceParameters.timeout)
            self.init(
                expectation: try Self.parseExpectation(arguments.value(for: .expect)),
                timeout: try timeout.map(WaitTimeout.init(validatingSeconds:))
            )
        }

        static func parseExpectation(_ value: HeistValue?) throws -> AccessibilityPredicate? {
            guard let value else { return nil }
            return try parsePredicate(value)
        }

        /// Parse a required `AccessibilityPredicate` object (the `wait`
        /// `predicate` field). Throws if missing or malformed.
        static func parseRequiredPredicate(_ value: HeistValue?) throws -> AccessibilityPredicate {
            guard let value else {
                throw SchemaValidationError(
                    field: FenceParameterKey.predicate.rawValue,
                    observed: "missing",
                    expected: "object"
                )
            }
            return try parsePredicate(value)
        }

        static func parsePredicate(_ value: HeistValue) throws -> AccessibilityPredicate {
            return try TheFence.HeistValuePayloadDecoder.decode(
                value,
                field: "expect",
                as: AccessibilityPredicate.self,
                includesRootInField: false,
                dataCorruptedHandling: .invalidRequest
            )
        }

    }

    // MARK: - Expectation Parsing

    /// Parse compact command input into the same typed expectation argument
    /// shape accepted by direct, MCP, batch, and heist request decoding.
    public nonisolated static func parseExpectationArgument(_ rawValue: String) throws -> HeistValue {
        do {
            return .object(try PublicJSONInputDecoder.decodeObject(
                from: rawValue,
                context: "Expectation JSON",
                rootMismatchMessage: "Expected expectation JSON object"
            ))
        } catch let error as PublicJSONInputError {
            throw FenceError.invalidRequest(error.message)
        } catch {
            throw FenceError.invalidRequest("Invalid expectation JSON: \(error.localizedDescription)")
        }
    }
}

import Testing
@testable import TheScore

@Test func `keyed uniqued keeps the first value for each key`() {
    struct Value: Equatable {
        let key: Int
        let value: String
    }

    let values = [
        Value(key: 2, value: "first"),
        Value(key: 1, value: "only"),
        Value(key: 2, value: "second"),
    ]

    #expect(values.uniqued(on: \.key) == Array(values.prefix(2)))
}

@Test func `keyed uniqued excludes keys already represented by a base`() {
    let values = ["existing", "new", "new", "later"]

    #expect(values.uniqued(on: \.self, excluding: ["existing"]) == ["new", "later"])
}

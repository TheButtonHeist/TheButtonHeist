extension HeistCanonicalSwiftDSLRenderer {
    func renderTimeout(_ timeout: WaitTimeout) -> String {
        timeout == defaultWaitTimeout ? "" : ", timeout: \(decimal(timeout.seconds))"
    }

    func line(_ text: String, _ indent: Int) -> String {
        "\(String(repeating: "    ", count: indent))\(text)"
    }

    func quote(_ value: String) -> String {
        CanonicalValueDescription.quoted(value)
    }

    func quote(_ value: HeistReferenceName) -> String {
        quote(value.rawValue)
    }

    func decimal(_ value: Double) -> String {
        CanonicalValueDescription.decimal(value)
    }
}

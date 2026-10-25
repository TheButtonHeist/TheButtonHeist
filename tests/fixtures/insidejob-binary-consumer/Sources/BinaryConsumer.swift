import SwiftUI

@main
struct BinaryConsumer: App {
    @State private var recorded = false

    var body: some Scene {
        WindowGroup {
            VStack {
                Text("InsideJob integration consumer")
                Button("Record") { recorded = true }
                if recorded { Text("Recorded") }
            }
        }
    }
}

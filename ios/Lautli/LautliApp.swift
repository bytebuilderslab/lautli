import SwiftUI

@main
struct LautliApp: App {
    @State private var controller = DictationController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
        }
    }
}

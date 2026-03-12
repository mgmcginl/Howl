import SwiftUI

@main
struct HowlIOSApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.bleManager)
                .environmentObject(model.audioEngine)
                .onOpenURL { url in
                    model.importFile(from: url)
                }
        }
    }
}

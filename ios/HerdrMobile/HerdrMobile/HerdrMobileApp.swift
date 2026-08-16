import SwiftUI

@main
struct HerdrMobileApp: App {
    @State private var session = SessionController()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HomeView()
            }
            .environment(session)
            .preferredColorScheme(.dark)
            .tint(HerdrInk.phosphor)
            .onAppear { session.start() }
        }
    }
}

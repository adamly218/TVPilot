import SwiftUI

@main
struct TVPilotApp: App {
    @State private var store = TVStore()
    @State private var remote = SamsungRemote()

    var body: some Scene {
        WindowGroup {
            ConnectView()
                .environment(store)
                .environment(remote)
                .preferredColorScheme(.dark)
                .tint(.blue)
                .onAppear {
                    remote.onToken = { token, id in store.setToken(token, for: id) }
                }
        }
    }
}

enum Haptics {
    static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

import SwiftUI

#if canImport(MWDATCore)
import MWDATCore
#endif

@main
struct VoiceBridgeApp: App {
    @StateObject private var glasses = GlassesManager()
    @StateObject private var settings = SettingsStore()

    init() {
        #if canImport(MWDATCore)
        // The Meta toolkit must be configured exactly once, before anything else
        // touches it. A failure here means the MWDAT block in Info.plist is wrong.
        do {
            try Wearables.configure()
        } catch {
            print("[DAT] configure failed: \(error)")
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(glasses)
                .environmentObject(settings)
                .onOpenURL { url in
                    // Meta AI sends the user back here after they approve the app.
                    #if canImport(MWDATCore)
                    Task { _ = try? await Wearables.shared.handleUrl(url) }
                    #endif
                }
        }
    }
}

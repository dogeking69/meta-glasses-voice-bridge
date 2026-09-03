import SwiftUI

/// Three tabs: talk to it, read what it did, configure it.
struct ContentView: View {
    var body: some View {
        TabView {
            TalkView()
                .tabItem { Label("Talk", systemImage: "mic.fill") }

            ChatView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

/// SettingsView is also presented as a sheet on first launch, so it needs a
/// wrapper to sit in a tab without a dismiss button that does nothing.
private struct SettingsTab: View {
    var body: some View {
        SettingsView(showsDoneButton: false)
    }
}

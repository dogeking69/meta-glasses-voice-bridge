import SwiftUI

struct SettingsView: View {
    /// False when shown as a tab, where there is nothing to dismiss.
    var showsDoneButton = true

    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var testResult: String?
    @State private var isTesting = false
    @State private var isPairing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        isPairing = true
                    } label: {
                        Label("Pair with your Mac", systemImage: "wave.3.right")
                    }
                } footer: {
                    Text(settings.macName.isEmpty
                         ? "Finds your Mac on the network and fills in everything below. Run ./pair.sh on the Mac first."
                         : "Paired with \(settings.macName). Pair again to move to another Mac.")
                }

                Section {
                    TextField("192.168.1.42", text: $settings.host)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                    TextField("8765", text: $settings.port)
                        .keyboardType(.numberPad)
                    ForEach(settings.otherHosts, id: \.self) { address in
                        Button {
                            settings.useHost(address)
                            testResult = nil
                        } label: {
                            Label(address, systemImage: "arrow.left.arrow.right")
                                .font(.footnote)
                        }
                    }
                } header: {
                    Text("Your Mac")
                } footer: {
                    Text(settings.otherHosts.isEmpty
                         ? "The listener prints this address when it starts up."
                         : "The other addresses this Mac answers on. Tap one to switch — useful away from home, or after your router hands out new addresses.")
                }

                Section {
                    SecureField("Shared secret", text: $settings.sharedSecret)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Shared secret")
                } footer: {
                    Text("Must exactly match shared_secret in the listener's config.toml. Stored in the iPhone Keychain.")
                }

                Section {
                    TextField(WakeWord.defaultPhrase, text: $settings.wakePhrase)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Wake phrase")
                } footer: {
                    Text("What you say in hands-free mode. Two distinct words work best — the glasses mic is phone-call quality, so single common words misfire. Leave empty for \"\(WakeWord.defaultPhrase)\".")
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test connection")
                            Spacer()
                            if isTesting { ProgressView() }
                        }
                    }
                    .disabled(!settings.isConfigured || isTesting)

                    if let testResult {
                        Text(testResult).font(.footnote)
                    }
                }
            }
            .sheet(isPresented: $isPairing) {
                PairingView().environmentObject(settings)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDoneButton {
                    Button("Done") { dismiss() }
                        .disabled(!settings.isConfigured)
                }
            }
        }
    }

    private func test() async {
        isTesting = true
        defer { isTesting = false }

        // Tries every address pairing found, and keeps the one that answered,
        // so a test run after moving network also fixes the setting.
        let reachable = await settings.recoverAddress()
        testResult = reachable
            ? "Reached your Mac at \(settings.host)."
            : "No answer. Check the listener is running and both devices are on the same Wi-Fi."
    }
}

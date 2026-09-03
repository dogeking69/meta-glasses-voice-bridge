import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.1.42", text: $settings.host)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                    TextField("8765", text: $settings.port)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Your Mac")
                } footer: {
                    Text("The listener prints this address when it starts up.")
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
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
                    .disabled(!settings.isConfigured)
            }
        }
    }

    private func test() async {
        guard let baseURL = settings.baseURL else { return }
        isTesting = true
        defer { isTesting = false }

        let client = ListenerClient(baseURL: baseURL, sharedSecret: settings.sharedSecret)
        let reachable = await client.checkHealth()
        testResult = reachable
            ? "Reached your Mac."
            : "No answer. Check the listener is running and both devices are on the same Wi-Fi."
    }
}

import SwiftUI

/// Connects the app to a Mac with a six-digit PIN instead of a 64-character
/// secret. Pick the Mac from the list, type what `./pair.sh` is showing on its
/// screen, and the address, port and secret all arrive together.
struct PairingView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var browser = MacBrowser()
    @State private var selected: MacBrowser.Mac?
    @State private var pin = ""
    @State private var isPairing = false
    @State private var problem: String?
    @FocusState private var pinFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if let selected {
                    pinSection(for: selected)
                } else {
                    macSection
                }

                if let problem {
                    Section { Text(problem).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle(selected == nil ? "Find your Mac" : "Enter the PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if selected != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Back") { back() }
                    }
                }
            }
            .onAppear { browser.start() }
            .onDisappear { browser.stop() }
        }
    }

    private var macSection: some View {
        Section {
            ForEach(browser.macs) { mac in
                Button {
                    selected = mac
                    problem = nil
                    pinFocused = true
                } label: {
                    HStack {
                        Text(mac.name).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            if browser.macs.isEmpty {
                HStack {
                    ProgressView()
                    Text("Looking…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Macs on this network")
        } footer: {
            if let failure = browser.failure {
                Text("Could not search the network: \(failure)")
            } else {
                Text("Your Mac appears here while the listener is running. Nothing yet? Start it with ./run.sh, and make sure both devices are on the same Wi-Fi.")
            }
        }
    }

    private func pinSection(for mac: MacBrowser.Mac) -> some View {
        Section {
            TextField("000000", text: $pin)
                .keyboardType(.numberPad)
                .font(.system(.title, design: .monospaced))
                .focused($pinFocused)
                .onChange(of: pin) { _, new in
                    pin = String(new.filter(\.isNumber).prefix(6))
                }

            Button {
                Task { await pair(with: mac) }
            } label: {
                HStack {
                    Text("Pair")
                    Spacer()
                    if isPairing { ProgressView() }
                }
            }
            .disabled(pin.count != 6 || isPairing)
        } header: {
            Text(mac.name)
        } footer: {
            Text("Run ./pair.sh on that Mac. It shows a six-digit PIN for two minutes.")
        }
    }

    private func back() {
        selected = nil
        pin = ""
        problem = nil
    }

    private func pair(with mac: MacBrowser.Mac) async {
        isPairing = true
        problem = nil
        defer { isPairing = false }

        guard let address = await MacBrowser.resolve(mac.endpoint) else {
            problem = "Found \(mac.name) but could not open a connection to it."
            return
        }

        do {
            let result = try await Pairing.claim(pin: pin, host: address.host, port: address.port)
            settings.adopt(result)
            dismiss()
        } catch {
            problem = error.localizedDescription
            pin = ""
        }
    }
}

import SwiftUI

struct CareLinkSettingsView: View {
    @ObservedObject var glucoseMonitor: GlucoseMonitor
    @ObservedObject var launchAtLogin = LaunchAtLogin.shared
    @Binding var showingSettings: Bool

    @State private var username = ""
    @State private var region: CareLinkRegion = .eu
    @State private var isAuthenticating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Button {
                    showingSettings = false
                } label: {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .buttonStyle(.borderless)
                Spacer()
            }

            Image(systemName: "sensor.tag.radiowaves.forward.fill")
                .font(.system(size: 36))
                .foregroundColor(.blue)

            Text("Medtronic CareLink Login")
                .font(.headline)

            // Form
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CareLink Username (Email)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("email@example.com", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Region")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("Region", selection: $region) {
                        ForEach(CareLinkRegion.allCases, id: \.self) { r in
                            Text(r.displayName).tag(r)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                Toggle("Launch at Login", isOn: $launchAtLogin.isEnabled)
                    .font(.caption)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Your CareLink account credentials are used to authorize the app via browser login.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // Buttons
            VStack(spacing: 8) {
                Button {
                    Task { await authenticate() }
                } label: {
                    if isAuthenticating {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Connect via Browser")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(username.isEmpty || isAuthenticating)

                if KeychainHelper.hasCareLinkCredentials {
                    Button("Sign Out") {
                        glucoseMonitor.logout()
                        username = ""
                        errorMessage = nil
                    }
                    .foregroundColor(.red)
                    .font(.caption)
                }
            }

            Spacer()

            Button("Quit GlucoBar") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(20)
        .onAppear {
            if let saved = KeychainHelper.getValue(for: .clUsername) {
                username = saved
            }
            if let rawRegion = KeychainHelper.getValue(for: .clCountry),
               let r = CareLinkRegion(rawValue: rawRegion) {
                region = r
            }
        }
    }

    private func authenticate() async {
        isAuthenticating = true
        errorMessage = nil

        glucoseMonitor.setupCareLinkService(username: username, region: region)
        let success = await glucoseMonitor.authenticate()

        if success {
            showingSettings = false
        } else {
            errorMessage = glucoseMonitor.error ?? "Connection failed"
        }

        isAuthenticating = false
    }
}

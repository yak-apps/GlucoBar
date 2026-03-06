import SwiftUI

struct LibreSettingsView: View {
    @ObservedObject var glucoseMonitor: GlucoseMonitor
    @ObservedObject var launchAtLogin = LaunchAtLogin.shared
    @Binding var showingSettings: Bool

    @State private var email = ""
    @State private var password = ""
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

            Image(systemName: "bandage.fill")
                .font(.system(size: 36))
                .foregroundColor(.orange)

            Text("FreeStyle Libre Login")
                .font(.headline)

            // Form
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LibreLinkUp Email")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("email@example.com", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Password")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
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

            Text("Use your LibreLinkUp account credentials. Region is detected automatically.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                Button {
                    Task { await authenticate() }
                } label: {
                    if isAuthenticating {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Connect")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(email.isEmpty || password.isEmpty || isAuthenticating)

                if KeychainHelper.hasLibreCredentials {
                    Button("Sign Out") {
                        glucoseMonitor.logout()
                        email = ""
                        password = ""
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
            if let saved = KeychainHelper.getValue(for: .libreEmail) {
                email = saved
            }
        }
    }

    private func authenticate() async {
        isAuthenticating = true
        errorMessage = nil

        glucoseMonitor.setupLibreService(email: email, password: password)
        let success = await glucoseMonitor.authenticate()

        if success {
            showingSettings = false
        } else {
            errorMessage = glucoseMonitor.error ?? "Connection failed"
        }

        isAuthenticating = false
    }
}

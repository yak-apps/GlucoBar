import SwiftUI

struct MenuBarView: View {
    @ObservedObject var glucoseMonitor: GlucoseMonitor
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            if showingSettings {
                SettingsView(glucoseMonitor: glucoseMonitor, showingSettings: $showingSettings)
            } else if !glucoseMonitor.isAuthenticated && !KeychainHelper.hasCredentials {
                setupPromptView
            } else {
                mainContentView
            }
        }
        .frame(width: 340)
    }

    private var setupPromptView: some View {
        VStack(spacing: 16) {
            Image(systemName: "drop.fill")
                .font(.system(size: 48))
                .foregroundColor(.blue)

            Text("Welcome to GlucoBar")
                .font(.headline)

            Text("Connect your Dexcom Share account to monitor glucose.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Set Up Dexcom") {
                showingSettings = true
            }
            .buttonStyle(.borderedProminent)

            Divider()

            Button("Quit GlucoBar") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
        }
        .padding(24)
    }

    private var mainContentView: some View {
        VStack(spacing: 0) {
            currentReadingView
                .padding()
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            GlucoseGraphView(readings: glucoseMonitor.threeHourReadings, range: glucoseMonitor.glucoseRange)
                .frame(height: 180)
                .padding()

            Divider()

            footerView
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
    }

    private var currentReadingView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                if let reading = glucoseMonitor.latestReading {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(reading.displayValue)
                            .font(.system(size: 42, weight: .medium, design: .rounded))
                            .monospacedDigit()

                        Text(reading.trendArrow.symbol)
                            .font(.system(size: 32))

                        Text("mmol/L")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .foregroundColor(reading.rangeStatus.color)

                    HStack(spacing: 8) {
                        Text(reading.trendArrow.description)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("•")
                            .foregroundColor(.secondary)

                        Text(glucoseMonitor.lastUpdatedText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if glucoseMonitor.isLoading {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if let error = glucoseMonitor.error {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.yellow)
                            Text("Error")
                                .font(.caption.bold())
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(error, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                        }
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    VStack {
                        Text("---")
                            .font(.system(size: 42, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                        Text("No data available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            Button {
                Task {
                    await glucoseMonitor.fetchReadings()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(glucoseMonitor.isLoading)
        }
    }

    private var footerView: some View {
        HStack {
            if glucoseMonitor.error != nil {
                Image(systemName: "exclamationmark.circle")
                    .foregroundColor(.yellow)
                    .font(.caption)
            }

            Spacer()

            Button("Settings") {
                showingSettings = true
            }
            .buttonStyle(.borderless)
            .font(.caption)

            Text("•")
                .foregroundColor(.secondary)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var glucoseMonitor: GlucoseMonitor
    @ObservedObject var launchAtLogin = LaunchAtLogin.shared
    @Binding var showingSettings: Bool

    @State private var username = ""
    @State private var password = ""
    @State private var region: DexcomRegion = .nonUS
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

            Image(systemName: "drop.fill")
                .font(.system(size: 36))
                .foregroundColor(.blue)

            Text("Dexcom Share Login")
                .font(.headline)

            // Form
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dexcom Username")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Email or phone number", text: $username)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Password")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Region")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: $region) {
                        Text("US").tag(DexcomRegion.us)
                        Text("Non-US").tag(DexcomRegion.nonUS)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
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

            Text("Use your Dexcom account that has the CGM sensor")
                .font(.caption2)
                .foregroundColor(.secondary)

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
                        Text("Connect")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(username.isEmpty || password.isEmpty || isAuthenticating)

                if KeychainHelper.hasCredentials {
                    Button("Sign Out") {
                        glucoseMonitor.logout()
                        username = ""
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
            if let saved = KeychainHelper.getValue(for: .username) {
                username = saved
            }
            if let savedRegion = KeychainHelper.getValue(for: .region),
               let r = DexcomRegion(rawValue: savedRegion) {
                region = r
            }
        }
    }

    private func authenticate() async {
        isAuthenticating = true
        errorMessage = nil

        glucoseMonitor.setupService(username: username, password: password, region: region)
        let success = await glucoseMonitor.authenticate()

        if success {
            showingSettings = false
        } else {
            errorMessage = glucoseMonitor.error ?? "Connection failed"
        }

        isAuthenticating = false
    }
}

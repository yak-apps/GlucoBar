import SwiftUI

struct CGMSelectionView: View {
    @ObservedObject var glucoseMonitor: GlucoseMonitor
    @Binding var showingSettings: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 40))
                    .foregroundColor(.blue)

                Text("Choose Your CGM")
                    .font(.headline)

                Text("Select your continuous glucose monitor to get started.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 20)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()

            // Dexcom option
            CGMOptionRow(
                icon: "drop.fill",
                iconColor: .green,
                title: "Dexcom",
                subtitle: "Share API · G6, G7, ONE",
                badge: nil
            ) {
                glucoseMonitor.selectSource(.dexcom)
                showingSettings = true
            }

            Divider()
                .padding(.leading, 56)

            // CareLink option
            CGMOptionRow(
                icon: "sensor.tag.radiowaves.forward.fill",
                iconColor: .blue,
                title: "Medtronic CareLink",
                subtitle: "Guardian 4 · 770G · 780G",
                badge: nil
            ) {
                glucoseMonitor.selectSource(.carelink)
                showingSettings = true
            }

            Divider()
                .padding(.leading, 56)

            // FreeStyle Libre
            CGMOptionRow(
                icon: "bandage.fill",
                iconColor: .orange,
                title: "FreeStyle Libre",
                subtitle: "Libre 2, Libre 3 · LibreLinkUp",
                badge: nil
            ) {
                glucoseMonitor.selectSource(.libre)
                showingSettings = true
            }

            Divider()

            Button("Quit GlucoBar") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.vertical, 12)
        }
        .frame(width: 340)
    }
}

// MARK: - CGMOptionRow

private struct CGMOptionRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(iconColor)
                    .frame(width: 32, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let badge = badge {
                    Text(badge)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                        .foregroundColor(.secondary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

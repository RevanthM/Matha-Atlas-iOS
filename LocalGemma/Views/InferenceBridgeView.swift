import SwiftUI

/// Operator controls for the local inference bridge.
///
/// The bridge is what lets the InspectAR glasses client run its prompts on this
/// phone's Gemma model, so everything a field user needs to pair — address,
/// port, token — is on this one screen.
struct InferenceBridgeView: View {
    @ObservedObject private var bridge = InferenceBridge.shared
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    @State private var revealToken = false
    @State private var copiedLabel: String?
    @State private var portText = ""

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                pairingSection
                behaviourSection
                activitySection
                securitySection
            }
            .navigationTitle("Inference bridge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { portText = String(bridge.port) }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            Toggle(isOn: $bridge.isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Serve local clients")
                    Text("Lets paired apps on this device or network use Gemma 4 E2B here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(bridge.runState.label)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Model", value: store.status == .unloaded ? "Not loaded" : "Gemma 4 E2B · \(store.status.label)")
        } header: {
            Text("Bridge")
        } footer: {
            Text("Requests are answered by the model already loaded for chat. Nothing is downloaded twice and no prompt leaves this iPhone.")
        }
    }

    private var pairingSection: some View {
        Section("Pairing") {
            LabeledContent("Base URL") {
                Text(bridge.advertisedBaseURL)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                Text("Port")
                Spacer()
                TextField("8765", text: $portText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.callout.monospaced())
                    .frame(width: 90)
                    .onSubmit(commitPort)
                    .onChange(of: portText) { _, _ in commitPort() }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Token")
                    Spacer()
                    Button(revealToken ? "Hide" : "Reveal") { revealToken.toggle() }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                }
                Text(revealToken ? bridge.token : String(repeating: "•", count: 24))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                copy(bridge.pairingPayload, label: "Pairing link copied")
            } label: {
                Label("Copy pairing link", systemImage: "doc.on.doc")
            }

            Button {
                copy(bridge.token, label: "Token copied")
            } label: {
                Label("Copy token only", systemImage: "key")
            }

            Button(role: .destructive) {
                bridge.regenerateToken()
                revealToken = false
                copiedLabel = "New token generated"
            } label: {
                Label("Regenerate token", systemImage: "arrow.triangle.2.circlepath")
            }

            if let copiedLabel {
                Text(copiedLabel)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    private var behaviourSection: some View {
        Section {
            Toggle("Keep the screen awake while serving", isOn: $bridge.keepScreenAwake)
        } footer: {
            Text("iOS suspends the bridge when Matha Atlas leaves the foreground. Keep this screen visible during a survey.")
        }
    }

    private var activitySection: some View {
        Section("Activity") {
            LabeledContent("Served", value: bridge.servedRequests.formatted())
            LabeledContent("Rejected", value: bridge.rejectedRequests.formatted())
            if let activity = bridge.lastActivity {
                VStack(alignment: .leading, spacing: 3) {
                    Text(activity.summary)
                        .font(.caption)
                    Text(activity.at.formatted(date: .omitted, time: .standard))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No requests yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var securitySection: some View {
        Section("How this is protected") {
            bullet("key.fill", "Every request must present the token above.")
            bullet("network.badge.shield.half.filled", "Connections from outside the local network are refused.")
            bullet("person.fill.checkmark", "One request at a time — chat always keeps priority.")
            bullet("lock.iphone", "Prompts, photos, and answers stay on this device.")
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.caption)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.cyan)
        }
    }

    // MARK: Helpers

    private var statusColor: Color {
        switch bridge.runState {
        case .serving: .green
        case .starting: .yellow
        case .failed: .red
        case .stopped: .secondary
        }
    }

    private func commitPort() {
        let digits = portText.filter(\.isNumber)
        if digits != portText { portText = digits }
        guard let value = Int(digits), (1_024...65_535).contains(value) else { return }
        bridge.port = value
    }

    private func copy(_ value: String, label: String) {
        UIPasteboard.general.string = value
        copiedLabel = label
    }
}

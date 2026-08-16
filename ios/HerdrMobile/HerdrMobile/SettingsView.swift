import SwiftUI

struct SettingsView: View {
    @Environment(SessionController.self) private var session
    @State private var healthLine: String?
    @State private var isProbing = false

    var body: some View {
        @Bindable var settings = session.settings
        Form {
            Section {
                TextField("http://100.x.x.x:8787", text: $settings.rawBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(HerdrType.mono)
                    .foregroundStyle(HerdrInk.paper)
                    .accessibilityLabel("Sidecar base URL")
                    .submitLabel(.done)
                    .onSubmit { session.applyBaseURL() }
                Button("Apply URL") {
                    session.applyBaseURL()
                }
                .accessibilityLabel("Apply sidecar URL")
            } header: {
                Text("Sidecar")
            } footer: {
                Text("HTTP to loopback, RFC1918, Tailscale 100.64/10, or *.ts.net. No auth — Tailscale is the boundary.")
                    .foregroundStyle(HerdrInk.mute)
            }

            Section {
                Button {
                    Task { await probe() }
                } label: {
                    HStack {
                        Text(isProbing ? "Probing…" : "Probe /health")
                        Spacer()
                        if isProbing {
                            ProgressView()
                                .tint(HerdrInk.phosphor)
                        }
                    }
                }
                .disabled(isProbing || session.settings.baseURL == nil)
                .accessibilityLabel("Probe sidecar health")

                if let healthLine {
                    Text(healthLine)
                        .font(HerdrType.meta)
                        .foregroundStyle(healthLine.hasPrefix("ok") ? HerdrInk.phosphor : HerdrInk.flare)
                }
            } header: {
                Text("Link")
            }

            Section {
                LabeledContent("Default") {
                    Text(SettingsStore.defaultBaseURL)
                        .font(HerdrType.meta)
                        .foregroundStyle(HerdrInk.mute)
                }
                LabeledContent("Socket") {
                    Text(socketPreview)
                        .font(HerdrType.meta)
                        .foregroundStyle(HerdrInk.mute)
                }
            } header: {
                Text("Resolved")
            }
        }
        .scrollContentBackground(.hidden)
        .background(HerdrInk.void)
        .tint(HerdrInk.phosphor)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(HerdrInk.void, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var socketPreview: String {
        guard let url = session.settings.baseURL,
              let ws = HerdrClient.webSocketURL(from: url)
        else { return "invalid" }
        return ws.absoluteString
    }

    private func probe() async {
        isProbing = true
        defer { isProbing = false }
        do {
            let health = try await session.probeHealth()
            healthLine = "ok v\(health.version) · herdr \(health.herdr ? "up" : "down")"
        } catch {
            healthLine = error.localizedDescription
        }
    }
}

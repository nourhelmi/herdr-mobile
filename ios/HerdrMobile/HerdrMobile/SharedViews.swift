import SwiftUI

struct ConnectionIndicator: View {
    var phase: ConnectionPhase
    var herdrOK: Bool?

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(filament)
                .frame(width: 18, height: 3)
                .shadow(color: filament.opacity(phase == .live ? 0.7 : 0), radius: 4)
                .accessibilityHidden(true)
            Text(title)
                .font(HerdrType.meta)
                .foregroundStyle(HerdrInk.paper)
                .textCase(.uppercase)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    private var title: String {
        switch phase {
        case .offline: return "offline"
        case .connecting: return "linking"
        case .live: return herdrOK == false ? "herdr down" : "live"
        case .reconnecting: return "retry"
        }
    }

    private var filament: Color {
        switch phase {
        case .offline: return HerdrInk.ash
        case .connecting, .reconnecting: return HerdrInk.hush
        case .live: return herdrOK == false ? HerdrInk.flare : HerdrInk.phosphor
        }
    }

    private var accessibility: String {
        switch phase {
        case .offline: return "Connection offline"
        case .connecting: return "Connecting to sidecar"
        case .reconnecting: return "Reconnecting to sidecar"
        case .live:
            return herdrOK == false
                ? "Connected to sidecar, Herdr poll failed"
                : "Connected to sidecar"
        }
    }
}

struct StateBadge: View {
    var state: String

    var body: some View {
        let label = AgentState.label(state)
        let color = AgentState.color(state)
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(HerdrType.meta)
                .foregroundStyle(color)
                .textCase(.uppercase)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Rectangle())
        .overlay(Rectangle().stroke(color.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("State \(label)")
    }
}

struct TerminalOutputView: View {
    var text: String
    var emptyMessage: String

    var body: some View {
        let display = ANSIStripper.displayText(text)
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if display.isEmpty {
                        Text(emptyMessage)
                            .font(HerdrType.meta)
                            .foregroundStyle(HerdrInk.mute)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(display)
                            .font(HerdrType.mono)
                            .foregroundStyle(HerdrInk.paper)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
                .id("tail")
            }
            .background(HerdrInk.inset)
            .onChange(of: display) {
                proxy.scrollTo("tail", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("tail", anchor: .bottom)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane output")
    }
}

struct QuickKeysBar: View {
    var enabled: Bool
    var onKey: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            key("ESC", send: "esc")
            key("^C", send: "ctrl+c")
            key("RET", send: "enter")
            Spacer()
        }
    }

    private func key(_ title: String, send: String) -> some View {
        Button {
            onKey(send)
        } label: {
            Text(title)
                .font(HerdrType.key)
                .foregroundStyle(enabled ? HerdrInk.void : HerdrInk.mute)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(enabled ? HerdrInk.paper : HerdrInk.rule, in: Rectangle())
        }
        .disabled(!enabled)
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityName(send))
    }

    private func accessibilityName(_ key: String) -> String {
        switch key {
        case "esc": return "Send escape"
        case "ctrl+c": return "Send control C"
        case "enter": return "Send enter"
        default: return "Send \(key)"
        }
    }
}

struct PromptComposer: View {
    @Binding var text: String
    var isSending: Bool
    var onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Prompt the agent", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(HerdrType.body)
                .foregroundStyle(HerdrInk.paper)
                .lineLimit(1...6)
                .padding(10)
                .background(HerdrInk.inset)
                .overlay(Rectangle().stroke(HerdrInk.rule, lineWidth: 1))
                .submitLabel(.send)
                .onSubmit(onSend)
                .accessibilityLabel("Prompt")
            Button(action: onSend) {
                Text(isSending ? "…" : "SEND")
                    .font(HerdrType.key)
                    .foregroundStyle(HerdrInk.void)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(canSend ? HerdrInk.phosphor : HerdrInk.rule)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send prompt")
        }
    }

    private var canSend: Bool {
        !isSending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct ErrorBanner: View {
    var message: String?

    var body: some View {
        if let message, !message.isEmpty {
            Text(message)
                .font(HerdrType.meta)
                .foregroundStyle(HerdrInk.flare)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Error \(message)")
        }
    }
}

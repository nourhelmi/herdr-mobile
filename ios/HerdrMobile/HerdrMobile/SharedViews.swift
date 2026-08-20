import SwiftUI
import UIKit

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
    /// Local composer text — shown instantly; sidecar echo still replaces the snapshot.
    var pendingEcho: String = ""

    var body: some View {
        // TextKit, not SwiftUI Text — full-snapshot ticks were relayouting one giant document.
        TerminalTextKitView(text: text, emptyMessage: emptyMessage)
            .background(HerdrInk.inset)
            .overlay(alignment: .bottomLeading) {
                if !pendingEcho.isEmpty {
                    Text(pendingEcho)
                        .font(HerdrType.mono)
                        .foregroundStyle(HerdrInk.phosphor)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(HerdrInk.void.opacity(0.88))
                        .accessibilityLabel("Pending input \(pendingEcho)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pane output")
    }
}

/// Read-only UITextView: incremental layout, pin-to-tail without ScrollViewReader.
private struct TerminalTextKitView: UIViewRepresentable {
    var text: String
    var emptyMessage: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = UIColor(HerdrInk.inset)
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.textContainer.lineFragmentPadding = 4
        view.alwaysBounceVertical = true
        view.indicatorStyle = .white
        // Dragging the output pulls the keyboard down with it, like Messages/Terminal.
        view.keyboardDismissMode = .interactive
        view.layoutManager.allowsNonContiguousLayout = true
        view.delegate = context.coordinator
        apply(text, to: view, coordinator: context.coordinator, forceScroll: true)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        apply(text, to: view, coordinator: context.coordinator, forceScroll: false)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var lastSource: String?
        var generation = 0
        var pinnedToTail = true
        var colorizeWork: DispatchWorkItem?

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            pinnedToTail = isNearTail(scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { pinnedToTail = isNearTail(scrollView) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            pinnedToTail = isNearTail(scrollView)
        }

        func isNearTail(_ scrollView: UIScrollView) -> Bool {
            scrollView.contentOffset.y + scrollView.bounds.height >= scrollView.contentSize.height - 48
        }
    }

    private func apply(
        _ raw: String,
        to view: UITextView,
        coordinator: Coordinator,
        forceScroll: Bool
    ) {
        guard coordinator.lastSource != raw else { return }
        coordinator.lastSource = raw
        coordinator.generation += 1
        let generation = coordinator.generation
        let emptyCopy = emptyMessage
        let pin = forceScroll || coordinator.pinnedToTail
        coordinator.colorizeWork?.cancel()

        // First paint: stripped mono. Color runs wait — and are coalesced while typing.
        let plain = ANSIStripper.displayText(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if plain.isEmpty {
            view.attributedText = Self.placeholder(emptyCopy)
        } else {
            view.attributedText = NSAttributedString(
                string: plain,
                attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: UIColor(HerdrInk.paper),
                ]
            )
        }
        if pin { Self.scrollToTail(view) }

        guard !plain.isEmpty else { return }
        let work = DispatchWorkItem {
            let rendered = ANSIRenderer.nsAttributed(raw)
            DispatchQueue.main.async {
                guard coordinator.generation == generation else { return }
                view.attributedText = rendered
                if coordinator.pinnedToTail { Self.scrollToTail(view) }
            }
        }
        coordinator.colorizeWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private static func placeholder(_ message: String) -> NSAttributedString {
        NSAttributedString(
            string: message,
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: UIColor(HerdrInk.mute),
            ]
        )
    }

    private static func scrollToTail(_ view: UITextView) {
        view.layoutIfNeeded()
        let end = max(view.text.count - 1, 0)
        view.scrollRangeToVisible(NSRange(location: end, length: 0))
    }
}

struct StatusChip: View {
    var label: String
    var emphasis = false

    var body: some View {
        Text(label)
            .font(HerdrType.meta)
            .foregroundStyle(emphasis ? HerdrInk.phosphor : HerdrInk.paper)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(HerdrInk.inset)
            .overlay(Rectangle().stroke(emphasis ? HerdrInk.phosphor.opacity(0.45) : HerdrInk.rule, lineWidth: 1))
    }
}

struct KeyCap: View {
    var title: String
    var send: String
    var enabled: Bool
    var onKey: (String) -> Void

    var body: some View {
        Button {
            onKey(send)
        } label: {
            Text(title)
                .font(HerdrType.key)
                .foregroundStyle(enabled ? HerdrInk.void : HerdrInk.mute)
                .padding(.horizontal, 10)
                // 44pt square: Apple HIG minimum tappable target, kept even as the cap shrinks visually.
                .frame(minWidth: 44, minHeight: 44)
                .background(enabled ? HerdrInk.paper : HerdrInk.rule, in: Rectangle())
        }
        .disabled(!enabled)
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityName)
    }

    private var accessibilityName: String {
        switch send {
        case "esc": return "Send escape"
        case "ctrl+c": return "Send control C"
        case "enter": return "Send enter"
        case "tab": return "Send tab"
        case "backspace": return "Send backspace"
        case "up": return "Send up arrow"
        case "down": return "Send down arrow"
        case "left": return "Send left arrow"
        case "right": return "Send right arrow"
        default: return "Send \(send)"
        }
    }
}

struct QuickKeysBar: View {
    var enabled: Bool
    var includeEnter = true
    var extended = false
    var onKey: (String) -> Void
    /// Compact explicit dismiss affordance, shown at the trailing end when provided.
    var onDismissKeyboard: (() -> Void)?

    var body: some View {
        // One scrollable row, not two stacked rows: the biggest single win for
        // dock height without dropping any key or shrinking touch targets.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                KeyCap(title: "ESC", send: "esc", enabled: enabled, onKey: onKey)
                KeyCap(title: "^C", send: "ctrl+c", enabled: enabled, onKey: onKey)
                if includeEnter {
                    KeyCap(title: "RET", send: "enter", enabled: enabled, onKey: onKey)
                }
                if extended {
                    KeyCap(title: "TAB", send: "tab", enabled: enabled, onKey: onKey)
                    KeyCap(title: "BSP", send: "backspace", enabled: enabled, onKey: onKey)
                    KeyCap(title: "↑", send: "up", enabled: enabled, onKey: onKey)
                    KeyCap(title: "↓", send: "down", enabled: enabled, onKey: onKey)
                    KeyCap(title: "←", send: "left", enabled: enabled, onKey: onKey)
                    KeyCap(title: "→", send: "right", enabled: enabled, onKey: onKey)
                }
                if let onDismissKeyboard {
                    Button(action: onDismissKeyboard) {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(HerdrType.key)
                            .foregroundStyle(HerdrInk.paper)
                            .padding(.horizontal, 10)
                            .frame(minWidth: 44, minHeight: 44)
                            .background(HerdrInk.rule, in: Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide keyboard")
                }
            }
        }
    }
}

/// Resigns whatever first responder is active, regardless of which text field owns it.
func dismissActiveKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

/// Backup to `UITextView.keyboardDismissMode = .interactive`: that native mode is driven by
/// the keyboard's own private pan tracking, which XCUITest's synthetic touch injection cannot
/// reliably drive. This is a plain, testable pan gesture that runs alongside every existing
/// gesture (scroll, horizontal quick-key scroll, taps) instead of intercepting them, and only
/// fires on a real vertical-dominant downward drag, not an incidental diagonal touch.
private struct PullDownToDismissKeyboard: ViewModifier {
    @State private var didDismiss = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 16, coordinateSpace: .local)
                .onChanged { value in
                    guard !didDismiss else { return }
                    let dy = value.translation.height
                    let dx = value.translation.width
                    guard dy > 40, dy > abs(dx) * 1.5 else { return }
                    didDismiss = true
                    dismissActiveKeyboard()
                }
                .onEnded { _ in didDismiss = false }
        )
    }
}

extension View {
    /// Pulling down anywhere over the terminal output/dock resigns the keyboard.
    func pullDownToDismissKeyboard() -> some View {
        modifier(PullDownToDismissKeyboard())
    }
}

struct PromptComposer: View {
    @Binding var text: String
    var isSending = false
    var placeholder = "Type into the pane"
    var sendLabel = "RET"
    var fieldAccessibilityLabel = "Terminal input"
    var sendAccessibilityLabel = "Send enter"
    var onSend: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // UIKit field — SwiftUI TextField + FocusState + keyboard toolbar was the first-tap hitch.
            TerminalComposerField(text: $text, placeholder: placeholder, onSubmit: onSend)
                // Fixed, not just minimum: a single-line field must never stretch to
                // soak up leftover VStack space meant for terminal output above it.
                .frame(height: 32)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(HerdrInk.inset)
                .overlay(Rectangle().stroke(HerdrInk.rule, lineWidth: 1))
                .accessibilityLabel(fieldAccessibilityLabel)
            Button(action: onSend) {
                Text(isSending ? "…" : sendLabel)
                    .font(HerdrType.key)
                    .foregroundStyle(HerdrInk.void)
                    .padding(.horizontal, 12)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(canSend ? HerdrInk.phosphor : HerdrInk.rule)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(sendAccessibilityLabel)
        }
    }

    private var canSend: Bool {
        !isSending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

}

/// Native UITextField so first keyboard doesn't rebuild a SwiftUI TextField + accessory.
private struct TerminalComposerField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.font = UIFont.preferredFont(forTextStyle: .body)
        field.textColor = UIColor(HerdrInk.paper)
        field.tintColor = UIColor(HerdrInk.phosphor)
        field.backgroundColor = .clear
        field.borderStyle = .none
        field.returnKeyType = .send
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor(HerdrInk.mute)]
        )
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .editingChanged)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.onSubmit = onSubmit
        if field.text != text {
            field.text = text
        }
        if field.placeholder != placeholder {
            field.attributedPlaceholder = NSAttributedString(
                string: placeholder,
                attributes: [.foregroundColor: UIColor(HerdrInk.mute)]
            )
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        @objc func changed(_ field: UITextField) {
            text.wrappedValue = field.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onSubmit()
            return false
        }
    }
}

struct NoticeBanner: View {
    var message: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(message)
                .font(HerdrType.meta)
                .foregroundStyle(HerdrInk.tide)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("OK", action: onDismiss)
                .font(HerdrType.meta)
                .foregroundStyle(HerdrInk.paper)
                .accessibilityLabel("Dismiss notice")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notice \(message)")
    }
}

enum CloseScopeCopy {
    static func paneMessage(title: String, paneId: String) -> String {
        "This closes pane \(title) (\(paneId))."
    }

    static func tabMessage(name: String, paneCount: Int) -> String {
        "This closes tab \(name) and its \(count(paneCount, noun: "pane"))."
    }

    static func workspaceMessage(name: String, tabCount: Int, paneCount: Int) -> String {
        "This closes workspace \(name), \(count(tabCount, noun: "tab")), and \(count(paneCount, noun: "pane"))."
    }

    private static func count(_ n: Int, noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
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

/// Shared composer dock for both agent and bare-pane terminal detail screens:
/// quick keys, printable-text composer, and an inline error banner.
struct TerminalInputDock: View {
    @Binding var terminalBuffer: String
    var errorMessage: String?
    var onKey: (String) -> Void
    var onTerminalChange: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ErrorBanner(message: errorMessage)
            QuickKeysBar(
                enabled: true,
                includeEnter: true,
                extended: true,
                onKey: { key in onKey(key) },
                onDismissKeyboard: dismissActiveKeyboard
            )
            PromptComposer(
                text: $terminalBuffer,
                onSend: { onKey("enter") }
            )
            .onChange(of: terminalBuffer) { _, newValue in
                onTerminalChange(newValue)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(HerdrInk.panel)
    }
}

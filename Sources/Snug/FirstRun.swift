import AppKit
import SwiftUI

/// The permissions screen: Screen Recording (required) and Accessibility (recommended), each with its live status.
struct FirstRunView: View {
    @AppStorage(Pref.hotKeyCode) private var hotKeyCode = 0
    @AppStorage(Pref.hotKeyModifiers) private var hotKeyModifiers = 0
    @State private var tucked = false
    var onLater: () -> Void = {}

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.22), radius: 9, y: 10)
                .scaleEffect(tucked ? 1 : 1.18)
                .onAppear { withAnimation(.spring(duration: 0.4, bounce: 0.45)) { tucked = true } }
            Text("snug")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .tracking(-0.5)
            Text("Snug needs Screen Recording to capture your screen. Accessibility lets it highlight buttons, sidebars, and other parts of apps, and copy their text exactly. Captures stay on this Mac. Nothing is uploaded.")
                .font(.system(size: 15))
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // macOS sends no notification when a permission changes, so the rows re-read both every second.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(spacing: 10) {
                    permission("Screen Recording", detail: "Required", granted: CGPreflightScreenCaptureAccess()) {
                        CGRequestScreenCaptureAccess()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                    permission("Accessibility", detail: "Recommended", granted: AXIsProcessTrusted()) { Accessibility.requestTrust() }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                step(1, Text("Press \(Text(Shortcut.label(code: hotKeyCode, modifiers: hotKeyModifiers)).bold()) anywhere to capture"))
                step(2, Text("Press \(Text("T").bold()) for Text, then drag over text to select it"))
                step(3, Text("Press \(Text("?").bold()), or click \(Text("?").bold()) at the bottom of the overlay, for every key"))
            }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Done", action: onLater)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.top, 6)
        }
        .padding(.horizontal, 44)
        .padding(.top, 28)
        .padding(.bottom, 36)
        .frame(width: 500)
    }

    private func permission(_ name: String, detail: String, granted: Bool, allow: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Allow", action: allow).buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func step(_ number: Int, _ text: Text) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: String(number))
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.08), in: Circle())
            text
        }
    }
}

import AppKit
import SwiftUI

/// The Screen Recording permission screen.
struct FirstRunView: View {
    @AppStorage(Pref.hotKeyLabel) private var shortcut = ""
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
            Text("To capture your screen, macOS needs you to turn on Screen Recording for Snug. Captures stay on this Mac. Nothing is uploaded.")
                .font(.system(size: 15))
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                step(1, Text("Open System Settings and switch on Snug"))
                step(2, Text("Press \(Text(shortcut).bold()) anywhere to capture"))
                step(3, Text("Press \(Text("?").bold()) in the overlay any time you forget a key"))
            }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Button("Later", action: onLater)
                    .buttonStyle(.bordered)
                Button("Open System Settings") {
                    CGRequestScreenCaptureAccess()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(.horizontal, 44)
        .padding(.top, 28)
        .padding(.bottom, 36)
        .frame(width: 500)
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

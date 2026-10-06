import AppKit
import SwiftUI

/// The Screen Recording permission screen.
struct FirstRunView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Snug needs Screen Recording")
                .font(.title2.bold())
            Text("Snug freezes your screen so you can pick exactly what to copy. Nothing leaves your Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Screen Recording Settings") {
                CGRequestScreenCaptureAccess()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("After you turn Snug on, quit and reopen it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 420)
    }
}

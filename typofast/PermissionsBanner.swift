import SwiftUI
import CoreGraphics
import AppKit

struct PermissionsBanner: View {
    @State private var screenRecordingGranted = CGPreflightScreenCaptureAccess()

    var body: some View {
        Group {
            if !screenRecordingGranted {
                banner
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private var banner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Screen Recording needed")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                Text("Required so OCR can read context around your cursor.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: grant) {
                Text("Grant")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.orange.opacity(0.18))
        )
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private func refresh() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    private func grant() {
        if !CGRequestScreenCaptureAccess() {
            openSettings()
        }
        refresh()
    }

    private func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}

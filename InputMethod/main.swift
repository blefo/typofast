import AppKit
import InputMethodKit

final class InputMethodAppDelegate: NSObject, NSApplicationDelegate {
    private var server: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.typofast.InputMethod"
        let serverName = "TypofastInputMethodServer"
        server = IMKServer(name: serverName, bundleIdentifier: bundleID)
    }
}

let app = NSApplication.shared
let delegate = InputMethodAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

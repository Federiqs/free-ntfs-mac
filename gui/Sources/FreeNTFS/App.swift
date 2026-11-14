import SwiftUI
import AppKit

struct FreeNTFSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(delegate.model)
        } label: {
            MenuBarIcon()
                .environmentObject(delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only (LSUIElement in Info.plist does the same for the
        // bundled app; this covers running the bare binary from `swift run`).
        NSApp.setActivationPolicy(.accessory)
        model.start()

        let key = "didShowSetupOnFirstLaunch"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            Windows.showSetup(model)
        }
    }
}

struct MenuBarIcon: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Image(systemName: model.menuBarSymbol)
            .accessibilityLabel("free-ntfs-mac")
    }
}

/// Plain AppKit windows for Setup and Log: reliable to open from a
/// menu-bar-only app, unlike SwiftUI Window scenes.
@MainActor
enum Windows {
    private static var open: [String: NSWindow] = [:]

    static func showSetup(_ model: AppModel) {
        show(id: "setup", title: "free-ntfs-mac Setup", size: NSSize(width: 620, height: 720)) {
            SetupView().environmentObject(model)
        }
    }

    static func showLog(_ model: AppModel) {
        show(id: "log", title: "free-ntfs-mac Log", size: NSSize(width: 760, height: 520)) {
            LogView()
        }
    }

    private static func show<V: View>(id: String, title: String, size: NSSize, content: () -> V) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = open[id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        open[id] = window
        window.makeKeyAndOrderFront(nil)
    }

    /// A modal confirmation (SwiftUI alerts inside a MenuBarExtra window are
    /// unreliable: the window can close underneath them).
    static func confirm(_ title: String, _ message: String, confirmTitle: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

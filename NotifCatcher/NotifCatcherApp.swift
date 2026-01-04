import SwiftUI
import ServiceManagement
import Combine
import Cocoa

// MARK: - Swizzling for Settings Window Sidebar
extension NSSplitViewItem {
    @nonobjc private static let swizzler: () = {
        let originalSelector = #selector(getter: canCollapse)
        let swizzledSelector = #selector(getter: swizzledCanCollapse)

        guard
            let originalMethod = class_getInstanceMethod(NSSplitViewItem.self, originalSelector),
            let swizzledMethod = class_getInstanceMethod(NSSplitViewItem.self, swizzledSelector)
        else { return }

        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()

    @objc private var swizzledCanCollapse: Bool {
        if let window = viewController.view.window,
           window.identifier?.rawValue == "SettingsWindow" {
            return false
        }
        return self.swizzledCanCollapse
    }

    static func swizzle() {
        _ = swizzler
    }
}

@available(macOS 14.0, *)
extension View {
    func removeSidebarToggle() -> some View {
        toolbar(removing: .sidebarToggle)
            .toolbar { Color.clear }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!
    var monitor: NotificationMonitor!
    var windowManager: FloatingNotificationManager!
    var settingsWindowController: NSWindowController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        
        // Initialize Core Services
        self.monitor = NotificationMonitor()
        self.windowManager = FloatingNotificationManager(monitor: monitor)
        
        // Auto-start monitoring if permission exists
        if monitor.permissionGranted {
            monitor.startMonitoring()
        }
        
        // Open Settings Window on Launch
        openSettingsWindow()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsWindow()
        return true
    }
    
    @objc func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        
        if let windowController = settingsWindowController {
            windowController.showWindow(nil)
            return
        }
        
        let width: CGFloat = 850
        let height: CGFloat = 600
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.identifier = NSUserInterfaceItemIdentifier("SettingsWindow")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = nil
        window.center()
        window.minSize = NSSize(width: 700, height: 500)
        window.isMovableByWindowBackground = true
        
        let settingsView = SettingsView(monitor: monitor, windowManager: windowManager)
        let hostingController = NSHostingController(rootView: settingsView)
        window.contentViewController = hostingController
        
        let windowController = NSWindowController(window: window)
        self.settingsWindowController = windowController
        windowController.showWindow(nil)
    }
}

@main
struct NotifCatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        NSSplitViewItem.swizzle()
    }
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

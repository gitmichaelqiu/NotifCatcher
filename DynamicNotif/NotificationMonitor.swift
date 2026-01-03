import Foundation
import ApplicationServices
import Cocoa
import Combine

// Updated struct to include resolved Icon
struct CapturedNotification: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let body: String
    let appName: String
    let icon: NSImage? // Added icon support
    let timestamp = Date()
}

// Global C-style callback
func observerCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let monitor = Unmanaged<NotificationMonitor>.fromOpaque(refcon).takeUnretainedValue()
    
    DispatchQueue.global(qos: .userInteractive).async {
        usleep(100000) // 100ms delay for UI population
        monitor.handleNewNotification(element: element)
    }
}

class NotificationMonitor: ObservableObject {
    @Published var latestNotification: CapturedNotification?
    @Published var permissionGranted: Bool = false
    @Published var isListening: Bool = false
    @Published var errorMessage: String? = nil
    
    private var observer: AXObserver?
    
    init() {
        self.permissionGranted = checkPermissions()
    }
    
    func checkPermissions() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    
    func startMonitoring() {
        self.errorMessage = nil
        guard checkPermissions() else {
            self.errorMessage = "Accessibility permission missing."
            return
        }
        
        guard let pid = findNotificationCenterPID() else {
            print("❌ Could not find Notification Center PID")
            DispatchQueue.main.async { self.errorMessage = "Could not find 'NotificationCenter'." }
            return
        }
        
        print("✅ Found Notification Center PID: \(pid)")
        
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        guard AXObserverCreate(pid, observerCallback, &observer) == .success, let axObserver = observer else {
            print("❌ Failed to create AXObserver")
            return
        }
        
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        
        let appElement = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(axObserver, appElement, kAXWindowCreatedNotification as CFString, selfPointer)
        
        DispatchQueue.main.async { self.isListening = true }
    }
    
    private func findNotificationCenterPID() -> pid_t? {
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "NotificationCenter"]
        
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(output) {
                return pid
            }
        } catch { }

        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.NotificationCenter" }) {
            return app.processIdentifier
        }
        return nil
    }
    
    func handleNewNotification(element: AXUIElement) {
        // Extract content including App Name
        let content = scanAndDismiss(element)
        
        if !content.title.isEmpty || !content.body.isEmpty {
            // Resolve Icon
            let icon = resolveAppIcon(appName: content.appName)
            
            DispatchQueue.main.async {
                print("🔔 Captured: \(content.title) from \(content.appName)")
                self.latestNotification = CapturedNotification(
                    title: content.title,
                    body: content.body,
                    appName: content.appName,
                    icon: icon
                )
            }
        }
    }
    
    private func resolveAppIcon(appName: String) -> NSImage? {
        guard !appName.isEmpty, appName != "System" else { return nil }
        
        // 1. Try to find running app by name
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) {
            return app.icon
        }
        
        // 2. Try to find app path by name
        if let path = NSWorkspace.shared.fullPath(forApplication: appName) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        
        return nil
    }
    
    // Updated scanner to find App Name via Image Description
    private func scanAndDismiss(_ root: AXUIElement) -> (title: String, body: String, appName: String) {
        var titles: [String] = []
        var detectedAppName: String = "System"
        var pendingDismissal: (() -> Void)? = nil

        func crawl(_ el: AXUIElement, depth: Int) {
            if depth > 5 { return }

            var children: AnyObject?
            let res = AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
            guard res == .success, let list = children as? [AXUIElement] else { return }

            for child in list {
                // 1. Attributes
                var role: AnyObject?
                AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
                let roleStr = role as? String ?? ""

                // 2. Text
                if roleStr == "AXStaticText" {
                    var val: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &val)
                    if let text = val as? String, !text.isEmpty {
                        titles.append(text)
                    }
                }
                
                // 3. App Name (via Icon Description)
                // macOS notifications usually contain an AXImage where the description is the App Name
                if roleStr == "AXImage" {
                    var desc: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &desc)
                    if let descStr = desc as? String, !descStr.isEmpty {
                        detectedAppName = descStr
                    }
                }

                // 4. Dismissal Logic (Same as before)
                if pendingDismissal == nil {
                    var subrole: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subrole)
                    let subroleStr = subrole as? String ?? ""

                    if subroleStr == "AXNotificationCenterBanner" || roleStr == "AXGroup" || roleStr == "AXButton" {
                        var actionNames: CFArray?
                        AXUIElementCopyActionNames(child, &actionNames)
                        if let names = actionNames as? [String] {
                            if let closeAction = names.first(where: { $0.localizedCaseInsensitiveContains("Close") }) {
                                pendingDismissal = { _ = AXUIElementPerformAction(child, closeAction as CFString) }
                            } else if names.contains("AXCancel") {
                                pendingDismissal = { _ = AXUIElementPerformAction(child, kAXCancelAction as CFString) }
                            }
                        }
                    }
                }
                
                crawl(child, depth: depth + 1)
            }
        }
        
        crawl(root, depth: 0)
        pendingDismissal?()
        
        let t = titles.first ?? "New Notification"
        let b = titles.count > 1 ? titles[1] : ""
        return (t, b, detectedAppName)
    }
}

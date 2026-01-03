import Foundation
import ApplicationServices
import Cocoa
import Combine

// A simple struct to hold notification data
struct CapturedNotification: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let body: String
    let appName: String
    let timestamp = Date()
}

// Global C-style callback function for the Accessibility API
func observerCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let monitor = Unmanaged<NotificationMonitor>.fromOpaque(refcon).takeUnretainedValue()
    
    DispatchQueue.global(qos: .userInteractive).async {
        // OPTIMIZATION: Removed usleep entirely.
        // We now process immediately to kill the banner as fast as possible.
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
        
        // ROBUST PID FINDING
        guard let pid = findNotificationCenterPID() else {
            print("❌ Could not find Notification Center PID")
            DispatchQueue.main.async {
                self.errorMessage = "Could not find 'NotificationCenter'.\nIs the Sandbox disabled in Project Settings?"
            }
            return
        }
        
        print("✅ Found Notification Center PID: \(pid)")
        
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        guard AXObserverCreate(pid, observerCallback, &observer) == .success, let axObserver = observer else {
            print("❌ Failed to create AXObserver")
            DispatchQueue.main.async {
                self.errorMessage = "Failed to create Observer.\nTry removing the App from Accessibility settings and re-adding it."
            }
            return
        }
        
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        
        let appElement = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(axObserver, appElement, kAXWindowCreatedNotification as CFString, selfPointer)
        
        DispatchQueue.main.async {
            self.isListening = true
        }
        print("👂 Monitoring started...")
    }
    
    // Helper: Finds PID using /usr/bin/pgrep
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
        } catch {
            print("Pgrep failed: \(error)")
        }

        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.NotificationCenter" }) {
            return app.processIdentifier
        }
        
        return nil
    }
    
    func handleNewNotification(element: AXUIElement) {
        // COMBINED PASS: Extract text and dismiss in a single tree traversal.
        // This is significantly faster than doing two separate passes.
        let (title, body) = scanAndDismiss(element)
        
        if !title.isEmpty || !body.isEmpty {
            DispatchQueue.main.async {
                print("🔔 Captured: \(title) - \(body)")
                self.latestNotification = CapturedNotification(title: title, body: body, appName: "System")
            }
        }
    }
    
    // Single-pass optimized scanner: Reads content AND kills the banner simultaneously
    private func scanAndDismiss(_ root: AXUIElement) -> (String, String) {
        var titles: [String] = []
        var dismissed = false

        func crawl(_ el: AXUIElement, depth: Int) {
            if depth > 5 { return } // Depth limit optimization

            var children: AnyObject?
            let res = AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
            guard res == .success, let list = children as? [AXUIElement] else { return }

            for child in list {
                // 1. GET BASIC ATTRIBUTES (Role is needed for both text and buttons)
                var role: AnyObject?
                AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
                let roleStr = role as? String ?? ""

                // 2. CHECK FOR TEXT
                if roleStr == "AXStaticText" {
                    var val: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &val)
                    if let text = val as? String, !text.isEmpty {
                        titles.append(text)
                    }
                }

                // 3. CHECK FOR DISMISSAL (If not already killed)
                if !dismissed {
                    var subrole: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subrole)
                    let subroleStr = subrole as? String ?? ""

                    // Check Actions (Expensive IPC, so only check promising elements)
                    if subroleStr == "AXNotificationCenterBanner" || roleStr == "AXGroup" || roleStr == "AXButton" {
                        var actionNames: CFArray?
                        AXUIElementCopyActionNames(child, &actionNames)
                        
                        if let names = actionNames as? [String] {
                            // Look for explicit "Close" action
                            if let closeAction = names.first(where: { $0.localizedCaseInsensitiveContains("Close") }) {
                                _ = AXUIElementPerformAction(child, closeAction as CFString)
                                dismissed = true
                            } else if names.contains("AXCancel") {
                                _ = AXUIElementPerformAction(child, kAXCancelAction as CFString)
                                dismissed = true
                            }
                        }
                    }

                    // Backup: Blind Cancel on Banner
                    if !dismissed && subroleStr == "AXNotificationCenterBanner" {
                        let err = AXUIElementPerformAction(child, kAXCancelAction as CFString)
                        if err == .success { dismissed = true }
                    }

                    // Backup: Standard Close Button
                    if !dismissed && roleStr == "AXButton" {
                        var title: AnyObject?
                        AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &title)
                        let titleStr = title as? String ?? ""
                        
                        if subroleStr == "AXCloseButton" || titleStr == "Close" || titleStr == "Clear" {
                            _ = AXUIElementPerformAction(child, kAXPressAction as CFString)
                            dismissed = true
                        }
                    }
                }
                
                // 4. RECURSE
                crawl(child, depth: depth + 1)
            }
        }
        
        crawl(root, depth: 0)
        
        let t = titles.first ?? "New Notification"
        let b = titles.count > 1 ? titles[1] : ""
        return (t, b)
    }
}

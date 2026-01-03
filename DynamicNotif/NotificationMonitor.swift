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
        // OPTIMIZATION: Reduced latency from 0.1s (100000) to 0.01s (10000)
        // This minimizes the time the system banner is visible before we kill it.
        usleep(10000)
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
        // 1. FAST READ: Grab text immediately
        let (title, body) = extractText(from: element)
        
        // 2. FAST KILL: Trigger dismissal immediately on background thread
        // We don't wait for UI updates to finish before killing the system banner.
        DispatchQueue.global(qos: .userInteractive).async {
            self.attemptDismiss(element: element)
        }
        
        // 3. UPDATE UI: Show our custom banner
        if !title.isEmpty || !body.isEmpty {
            DispatchQueue.main.async {
                print("🔔 Captured: \(title) - \(body)")
                self.latestNotification = CapturedNotification(title: title, body: body, appName: "System")
            }
        }
    }
    
    // OPTIMIZED: Faster dismissal by targeting the specific banner component
    private func attemptDismiss(element: AXUIElement) {
        // Perform a targeted crawl. We know the "Close" action lives on the 'AXNotificationCenterBanner'
        // or a child with 'AXCloseButton'. We stop as soon as we succeed.
        _ = fastCrawlAndDismiss(element, depth: 0)
    }

    private func performPress(element: AXUIElement) {
        _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
    }
    
    private func performCancel(element: AXUIElement) {
        _ = AXUIElementPerformAction(element, kAXCancelAction as CFString)
    }

    // Returns true if dismissed, to stop further searching
    private func fastCrawlAndDismiss(_ el: AXUIElement, depth: Int) -> Bool {
        // Optimization: Don't go too deep
        if depth > 5 { return false }

        var children: AnyObject?
        let res = AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
        guard res == .success, let list = children as? [AXUIElement] else { return false }
        
        for child in list {
            var subrole: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subrole)
            let subroleStr = subrole as? String ?? ""

            // CHECK ACTIONS (Priority)
            // We check actions on every node because sometimes the wrapper has the action
            var actionNames: CFArray?
            AXUIElementCopyActionNames(child, &actionNames)
            
            if let names = actionNames as? [String] {
                // 1. Look for explicit "Close" action (found in logs earlier)
                if let closeAction = names.first(where: { $0.localizedCaseInsensitiveContains("Close") }) {
                    let err = AXUIElementPerformAction(child, closeAction as CFString)
                    if err == .success { return true }
                }
                
                // 2. Look for Cancel
                if names.contains("AXCancel") {
                    performCancel(element: child)
                    return true
                }
            }

            // CHECK SUBROLE (Targeting the Banner Group)
            // If this is the banner, and we haven't found a named action, try blind cancel
            if subroleStr == "AXNotificationCenterBanner" {
                // Attempt blind cancel just in case
                let err = AXUIElementPerformAction(child, kAXCancelAction as CFString)
                if err == .success { return true }
            }
            
            // CHECK BUTTONS (Traditional Close Button)
            var role: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            let roleStr = role as? String ?? ""
            
            if roleStr == "AXButton" {
                var title: AnyObject?
                AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &title)
                let titleStr = title as? String ?? ""
                
                if subroleStr == "AXCloseButton" || titleStr == "Close" || titleStr == "Clear" {
                    performPress(element: child)
                    return true
                }
            }
            
            // Recurse
            if fastCrawlAndDismiss(child, depth: depth + 1) {
                return true
            }
        }
        return false
    }
    
    private func extractText(from element: AXUIElement) -> (String, String) {
        var titles: [String] = []
        
        func crawl(_ el: AXUIElement) {
            var children: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
            
            if let list = children as? [AXUIElement] {
                for child in list {
                    var role: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
                    
                    if let r = role as? String, r == "AXStaticText" {
                        var val: AnyObject?
                        AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &val)
                        if let text = val as? String, !text.isEmpty {
                            titles.append(text)
                        }
                    }
                    crawl(child)
                }
            }
        }
        
        crawl(element)
        let t = titles.first ?? "New Notification"
        let b = titles.count > 1 ? titles[1] : ""
        return (t, b)
    }
}

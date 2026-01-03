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
        usleep(100000) // 0.1s delay for text rendering
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
        let (title, body) = extractText(from: element)
        
        if !title.isEmpty || !body.isEmpty {
            DispatchQueue.main.async {
                print("🔔 Captured: \(title) - \(body)")
                self.latestNotification = CapturedNotification(title: title, body: body, appName: "System")
            }
            
            self.attemptDismiss(element: element)
        }
    }
    
    // UPDATED: Dismissal with ACTION INSPECTION
    private func attemptDismiss(element: AXUIElement) {
        // Strategy 1: Check for the Standard Window Close Button Attribute
        var closeButtonRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButtonRef)
        
        if result == .success, let closeButton = closeButtonRef {
            let closeEl = closeButton as! AXUIElement
            print("   🎯 Found Standard Close Button via Attribute.")
            performPress(element: closeEl)
            return
        }
        
        // Strategy 2: Deep recursive crawl looking for Actions
        print("   ⚠️ Standard attribute failed. Scanning for Actions & Hidden buttons...")
        crawlAndDismiss(element, depth: 0)
    }

    private func performPress(element: AXUIElement) {
        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if error == .success {
            print("   ✨ Dismissed successfully (AXPress)")
        } else {
            print("   ⚠️ Failed to press: \(error.rawValue)")
        }
    }
    
    private func performCancel(element: AXUIElement) {
        let error = AXUIElementPerformAction(element, kAXCancelAction as CFString)
        if error == .success {
            print("   ✨ Dismissed successfully (AXCancel)")
        } else {
            print("   ⚠️ Failed to cancel: \(error.rawValue)")
        }
    }

    private func crawlAndDismiss(_ el: AXUIElement, depth: Int) {
        var children: AnyObject?
        let res = AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
        
        guard res == .success, let list = children as? [AXUIElement] else {
            return
        }
        
        for child in list {
            var role: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            let roleStr = role as? String ?? "Unknown"
            
            var subrole: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subrole)
            let subroleStr = subrole as? String ?? ""

            // DEBUG LOGGING: Show the tree structure
            let indent = String(repeating: " ", count: depth * 2)
            print("\(indent)➡️ [\(roleStr)] Subrole:'\(subroleStr)'")
            
            // CHECK ACTIONS
            var actionNames: CFArray?
            AXUIElementCopyActionNames(child, &actionNames)
            if let names = actionNames as? [String] {
                print("\(indent)   ⚡️ Actions: \(names)")
                
                // STRATEGY UPDATE: Look for ANY action containing "Close"
                // Your logs showed: "Name:Close\nTarget:0x0..."
                if let closeAction = names.first(where: { $0.localizedCaseInsensitiveContains("Close") }) {
                    print("\(indent)   🔥 Found Explicit Close Action: '\(closeAction)'")
                    let err = AXUIElementPerformAction(child, closeAction as CFString)
                    if err == .success {
                        print("\(indent)   ✨ Executed Close Action Successfully!")
                        return
                    } else {
                         print("\(indent)   ⚠️ Failed to execute action: \(err.rawValue)")
                    }
                }
                
                // Fallback: AXCancel
                if names.contains("AXCancel") {
                    print("\(indent)   🔥 Found AXCancel! Executing...")
                    performCancel(element: child)
                    // Don't return here immediately, in case the explicit Close is better
                }
            }

            // CHECK 1: Explicit AXCloseButton
            if (roleStr == "AXButton" && subroleStr == "AXCloseButton") {
                print("\(indent)   🔥 MATCH! Clicking Button...")
                performPress(element: child)
                return
            }
            
            // Recurse
            crawlAndDismiss(child, depth: depth + 1)
        }
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

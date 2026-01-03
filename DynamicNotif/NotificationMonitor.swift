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
        
        // ROBUST PID FINDING (Reverted to Shell method which is more reliable for 'hacker' tools)
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
    
    // Helper: Finds PID using /usr/bin/pgrep (Reliable) or NSWorkspace (Fallback)
    private func findNotificationCenterPID() -> pid_t? {
        // Attempt 1: The "Hacker" way (Shell/pgrep)
        // We use absolute path /usr/bin/pgrep because $PATH might not be set in Xcode apps.
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        // Explicitly point to the binary to avoid PATH issues
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

        // Attempt 2: Native NSWorkspace (Fallback - usually only works if NC has a visible window)
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

import Foundation
import ApplicationServices
import Cocoa
internal import Combine

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
    // Convert the unsafe pointer back to our Swift object
    let monitor = Unmanaged<NotificationMonitor>.fromOpaque(refcon).takeUnretainedValue()
    
    // Process on background queue to avoid blocking UI, then sync back to Main
    DispatchQueue.global(qos: .userInteractive).async {
        // Small delay to let the UI settle (text rendering)
        usleep(100000) // 0.1s
        monitor.handleNewNotification(element: element)
    }
}

class NotificationMonitor: ObservableObject {
    @Published var latestNotification: CapturedNotification?
    @Published var permissionGranted: Bool = false
    @Published var isListening: Bool = false
    
    private var observer: AXObserver?
    
    init() {
        self.permissionGranted = checkPermissions()
    }
    
    func checkPermissions() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    
    func startMonitoring() {
        guard checkPermissions() else { return }
        
        // 1. Find Notification Center PID
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.arguments = ["-c", "pgrep -x NotificationCenter"]
        task.launchPath = "/bin/zsh"
        task.launch()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = pid_t(output) else {
            print("❌ Could not find Notification Center PID")
            return
        }
        
        print("✅ Found Notification Center PID: \(pid)")
        
        // 2. Create the Observer
        // We pass 'self' as a pointer (refcon) so the callback knows which instance to update
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        guard AXObserverCreate(pid, observerCallback, &observer) == .success, let axObserver = observer else {
            print("❌ Failed to create AXObserver")
            return
        }
        
        // 3. Add source to RunLoop
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        
        // 4. Watch for Window Created (Banner appearing)
        let appElement = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(axObserver, appElement, kAXWindowCreatedNotification as CFString, selfPointer)
        
        self.isListening = true
        print("👂 Monitoring started...")
    }
    
    // Called by the global callback
    func handleNewNotification(element: AXUIElement) {
        // Recursively read the element
        let (title, body) = extractText(from: element)
        
        if !title.isEmpty || !body.isEmpty {
            DispatchQueue.main.async {
                print("🔔 Captured: \(title) - \(body)")
                self.latestNotification = CapturedNotification(title: title, body: body, appName: "System")
            }
            
            // OPTIONAL: Try to close the system notification to complete the "Reshape" illusion
            // attemptDismiss(element: element)
        }
    }
    
    private func extractText(from element: AXUIElement) -> (String, String) {
        var titles: [String] = []
        
        // Helper to crawl the tree
        func crawl(_ el: AXUIElement) {
            // Check Children
            var children: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
            
            if let list = children as? [AXUIElement] {
                for child in list {
                    // Check Role
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
        
        // Heuristic: Usually the first text is Title, second is Body
        let t = titles.first ?? "New Notification"
        let b = titles.count > 1 ? titles[1] : ""
        
        return (t, b)
    }
    
    private func attemptDismiss(element: AXUIElement) {
        // Logic to find 'AXButton' with title 'Close' and perform kAXPressAction
        // (Simplified for brevity, refer to previous conversation for full implementation)
    }
}

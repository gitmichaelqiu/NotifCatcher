import Cocoa
import ApplicationServices
import Foundation

// 1. Helper to run shell commands (to find the PID)
func shell(_ command: String) -> String? {
    let task = Process()
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    task.arguments = ["-c", command]
    task.launchPath = "/bin/zsh"
    task.launch()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return output
}

// 2. Find the Notification Center PID using 'pgrep'
func getNotificationCenterPID() -> pid_t? {
    // We look for the process named "NotificationCenter" exactly
    if let output = shell("pgrep -x NotificationCenter"), let pid = Int32(output) {
        return pid
    }
    return nil
}

// 3. Callback when a UI element is created (Notification Banner)
let observerCallback: AXObserverCallback = { (observer, element, notification, refcon) in
    // Short delay to ensure text is rendered
    usleep(200000) // 0.2 seconds
    
    print("\n🔔 New Event Detected!")
    readContent(of: element)
}

func readContent(of element: AXUIElement) {
    var children: AnyObject?
    let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
    
    if result == .success, let childrenList = children as? [AXUIElement] {
        for child in childrenList {
            // Get the role of the element (Text, Image, etc.)
            var role: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            
            if let roleStr = role as? String {
                // If it is text, print it
                if roleStr == "AXStaticText" {
                    var value: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &value)
                    if let text = value as? String, !text.isEmpty {
                        print("   📄 Found Text: \(text)")
                    }
                }
            }
            // Recurse deeper into the UI structure
            readContent(of: child)
        }
    }
}

func checkPermissions() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

func startListening() {
    print("🔍 Searching for Notification Center PID via pgrep...")
    
    guard let pid = getNotificationCenterPID() else {
        print("❌ Could not find Notification Center PID. (Is macOS running?)")
        return
    }
    
    print("✅ Found Notification Center at PID: \(pid)")
    
    var observer: AXObserver?
    guard AXObserverCreate(pid, observerCallback, &observer) == .success, let axObserver = observer else {
        print("❌ Failed to create AXObserver. (Check Accessibility Permissions!)")
        return
    }
    
    let notificationElement = AXUIElementCreateApplication(pid)
    
    // Watch for "Window Created" (Banner appearing)
    let resultCreated = AXObserverAddNotification(axObserver, notificationElement, kAXWindowCreatedNotification as CFString, nil)
    
    // Also watch for "UI Element Destroyed" just to see when they leave (Optional)
    // AXObserverAddNotification(axObserver, notificationElement, kAXUIElementDestroyedNotification as CFString, nil)
    
    if resultCreated == .success {
        print("👂 Listening for incoming banners...")
        print("(Try sending a test notification now)")
        
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        CFRunLoopRun()
    } else {
        print("❌ Failed to subscribe to notifications. Error: \(resultCreated.rawValue)")
    }
}

// Main execution
if checkPermissions() {
    startListening()
} else {
    print("⚠️ Please grant Accessibility permissions to your terminal app.")
}

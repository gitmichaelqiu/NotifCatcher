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
    let icon: NSImage?
    let timestamp = Date()
}

// Global C-style callback
func observerCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let monitor = Unmanaged<NotificationMonitor>.fromOpaque(refcon).takeUnretainedValue()
    
    DispatchQueue.global(qos: .userInteractive).async {
        // Increased delay to 0.15s to ensure full accessibility tree population
        usleep(150000)
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
        let content = scanAndDismiss(element)
        
        if !content.title.isEmpty || !content.body.isEmpty {
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
        print("[IconDebug] Resolving icon for appName: '\(appName)'")
        
        guard !appName.isEmpty, appName != "System" else {
            print("[IconDebug] AppName is System/Empty. Skipping.")
            return nil
        }
        
        // 1. Exact Match
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) {
            return app.icon
        }
        
        // 2. Case-Insensitive
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(appName) == true }) {
            return app.icon
        }
        
        // 3. Manual Path Check
        let fileManager = FileManager.default
        let commonPaths = [
            "/Applications/\(appName).app",
            "/System/Applications/\(appName).app",
            "/System/Applications/Utilities/\(appName).app",
            "/Users/\(NSUserName())/Applications/\(appName).app"
        ]
        
        for path in commonPaths {
            if fileManager.fileExists(atPath: path) {
                return NSWorkspace.shared.icon(forFile: path)
            }
        }
        
        return nil
    }
    
    private func scanAndDismiss(_ root: AXUIElement) -> (title: String, body: String, appName: String) {
        var titles: [String] = []
        var detectedAppName: String = "System"
        var pendingDismissal: (() -> Void)? = nil

        // Check Root Window Title
        var windowTitle: AnyObject?
        AXUIElementCopyAttributeValue(root, kAXTitleAttribute as CFString, &windowTitle)
        if let wTitle = windowTitle as? String {
             print("[TreeDebug] Root Window Title: '\(wTitle)'")
            if wTitle != "Notification Center" && wTitle != "Window" && !wTitle.isEmpty {
                 detectedAppName = wTitle
            }
        }

        func crawl(_ el: AXUIElement, depth: Int) {
            if depth > 8 { return }

            var children: AnyObject?
            let res = AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
            guard res == .success, let list = children as? [AXUIElement] else { return }

            for child in list {
                // 1. Role & Subrole
                var role: AnyObject?
                AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
                let roleStr = role as? String ?? "Unknown"
                
                var subrole: AnyObject?
                AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subrole)
                let subroleStr = subrole as? String ?? ""

                // ENABLED DEBUG PRINT FOR DIAGNOSIS
                print("[TreeDebug] Depth: \(depth) | Role: \(roleStr) | Subrole: \(subroleStr)")

                // 2. Text Content
                if roleStr == "AXStaticText" {
                    var val: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &val)
                    if let text = val as? String, !text.isEmpty {
                        print("[TreeDebug]    -> Text Value: '\(text)'")
                        titles.append(text)
                    }
                }
                
                // 3. App Name Detection Strategy
                
                // Strategy A: AXImage Description or Title
                if roleStr == "AXImage" {
                    var desc: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &desc)
                    if let descStr = desc as? String, !descStr.isEmpty {
                        print("[IconDebug] Found AXImage Description: '\(descStr)'")
                        detectedAppName = descStr
                    }
                    
                    var title: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &title)
                    if let titleStr = title as? String, !titleStr.isEmpty {
                        print("[IconDebug] Found AXImage Title: '\(titleStr)'")
                        if detectedAppName == "System" { detectedAppName = titleStr }
                    }
                }
                
                // Strategy B: AXButton Description/Title
                if roleStr == "AXButton" {
                    var desc: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &desc)
                    if let descStr = desc as? String, !descStr.isEmpty, descStr != "Close", descStr != "Clear", descStr != "Actions" {
                        print("[IconDebug] Found AXButton Description: '\(descStr)'")
                        detectedAppName = descStr
                    }
                }
                
                // Strategy C: AXGroup Description (UPDATED to parse "AppName, Title, Body")
                if roleStr == "AXGroup" {
                    var desc: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &desc)
                    if let descStr = desc as? String, !descStr.isEmpty {
                        print("[GroupDebug] AXGroup Description: '\(descStr)'")
                        
                        // Case 1: "Notification from AppName"
                        if descStr.hasPrefix("Notification from ") {
                            detectedAppName = String(descStr.dropFirst(18))
                        }
                        // Case 2: "AppName, Title, Body" (matches "Discord, MickyMike, wowowow")
                        else if descStr.contains(", ") {
                            let components = descStr.components(separatedBy: ", ")
                            // Heuristic: The first component is likely the App Name
                            if let first = components.first, !first.isEmpty {
                                detectedAppName = first
                            }
                        }
                    }
                }

                // 4. Dismissal Logic
                if pendingDismissal == nil {
                    var actionNames: CFArray?
                    AXUIElementCopyActionNames(child, &actionNames)
                    
                    if let names = actionNames as? [String] {
                         if let closeAction = names.first(where: { $0.localizedCaseInsensitiveContains("Close") }) {
                             pendingDismissal = { _ = AXUIElementPerformAction(child, closeAction as CFString) }
                         } else if names.contains("AXCancel") {
                             pendingDismissal = { _ = AXUIElementPerformAction(child, kAXCancelAction as CFString) }
                         }
                    }
                    
                    if pendingDismissal == nil && subroleStr == "AXNotificationCenterBanner" {
                         pendingDismissal = { _ = AXUIElementPerformAction(child, kAXCancelAction as CFString) }
                    }
                    
                    if pendingDismissal == nil && roleStr == "AXButton" {
                        var title: AnyObject?
                        AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &title)
                        let titleStr = title as? String ?? ""
                        if subroleStr == "AXCloseButton" || titleStr == "Close" || titleStr == "Clear" {
                            pendingDismissal = { _ = AXUIElementPerformAction(child, kAXPressAction as CFString) }
                        }
                    }
                }
                
                crawl(child, depth: depth + 1)
            }
        }
        
        crawl(root, depth: 0)
        
        if let dismissal = pendingDismissal {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
                dismissal()
            }
        }
        
        let t = titles.first ?? "New Notification"
        let b = titles.count > 1 ? titles[1] : ""
        return (t, b, detectedAppName)
    }
}

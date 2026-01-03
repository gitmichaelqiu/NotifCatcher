import Foundation
import ApplicationServices
import Cocoa
import Combine
import ScreenCaptureKit // Required for modern screenshot capturing

// Updated struct to include resolved Icon AND Profile Photo
struct CapturedNotification: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let body: String
    let appName: String
    let icon: NSImage?
    let profileImage: NSImage? // NEW: For capturing sender avatars
    let timestamp = Date()
}

// Global C-style callback
func observerCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let monitor = Unmanaged<NotificationMonitor>.fromOpaque(refcon).takeUnretainedValue()
    
    DispatchQueue.global(qos: .userInteractive).async {
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
        // 1. Scan the tree to find text and the candidate element for the profile photo
        let content = scanAndDismiss(element)
        
        if !content.title.isEmpty || !content.body.isEmpty {
            let icon = resolveAppIcon(appName: content.appName)
            
            // 2. Perform Async Snapshot (if a profile element was found)
            Task {
                var profileImg: NSImage? = nil
                
                if let profileElement = content.profileElement {
                    print("[SnapshotDebug] Starting async snapshot capture...")
                    profileImg = await captureSnapshot(of: profileElement)
                    print("[SnapshotDebug] Snapshot result: \(profileImg == nil ? "Failed" : "Success")")
                } else {
                    print("[SnapshotDebug] No profile element candidate found.")
                }
                
                // 3. Update UI on Main Thread
                let finalNotification = CapturedNotification(
                    title: content.title,
                    body: content.body,
                    appName: content.appName,
                    icon: icon,
                    profileImage: profileImg
                )
                
                DispatchQueue.main.async {
                    print("🔔 Captured: \(finalNotification.title) from \(finalNotification.appName)")
                    self.latestNotification = finalNotification
                }
            }
        }
    }
    
    private func resolveAppIcon(appName: String) -> NSImage? {
        guard !appName.isEmpty, appName != "System" else { return nil }
        
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) { return app.icon }
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(appName) == true }) { return app.icon }
        
        let fileManager = FileManager.default
        let commonPaths = [
            "/Applications/\(appName).app",
            "/System/Applications/\(appName).app",
            "/System/Applications/Utilities/\(appName).app",
            "/Users/\(NSUserName())/Applications/\(appName).app"
        ]
        
        for path in commonPaths {
            if fileManager.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
        }
        return nil
    }
    
    // NEW: Async capture using ScreenCaptureKit for modern macOS
    private func captureSnapshot(of element: AXUIElement) async -> NSImage? {
        // 1. Get Position (Sync AX API)
        var posValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        
        // 2. Get Size (Sync AX API)
        var sizeValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        
        var position = CGPoint.zero
        var size = CGSize.zero
        
        // Fix: Removed redundant 'as? AXValue' checks that caused warnings
        if let pos = posValue { AXValueGetValue(pos as! AXValue, .cgPoint, &position) }
        if let sz = sizeValue { AXValueGetValue(sz as! AXValue, .cgSize, &size) }
        
        print("[SnapshotDebug] Element found at \(position.x),\(position.y) with size \(size.width)x\(size.height)")
        
        // Validation
        if size.width < 10 || size.height < 10 {
            print("[SnapshotDebug] -> Element too small (<10px). Skipping.")
            return nil
        }
        
        // Construct the global screen rect for the element
        let globalRect = CGRect(origin: position, size: size)
        
        // 3. Capture Strategy
        if #available(macOS 14.0, *) {
            return await captureViaScreenCaptureKit(rect: globalRect)
        }
        
        print("[SnapshotDebug] -> macOS version too old for ScreenCaptureKit.")
        return nil
    }
    
    // Helper: Modern ScreenCaptureKit implementation
    @available(macOS 14.0, *)
    private func captureViaScreenCaptureKit(rect: CGRect) async -> NSImage? {
        do {
            let content = try await SCShareableContent.current
            
            // Find the display that contains the element
            // We look for a display where the frame intersects our element's rect
            guard let display = content.displays.first(where: { $0.frame.intersects(rect) }) else {
                print("[SnapshotDebug] SCK: No display found intersecting rect: \(rect)")
                return nil
            }
            
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            
            // Convert Global Rect to Display-Local Rect
            // SCK sourceRect is usually relative to the display's origin if filtering by display.
            let localOrigin = CGPoint(x: rect.minX - display.frame.minX, y: rect.minY - display.frame.minY)
            let localRect = CGRect(origin: localOrigin, size: rect.size)
            
            config.sourceRect = localRect
            config.showsCursor = false
            
            // Handle Retina Scaling
            // We use deviceDescription to find the NSScreen matching the SCDisplay ID
            let scale = NSScreen.screens.first(where: { screen in
                guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                return num.uint32Value == display.displayID
            })?.backingScaleFactor ?? 2.0
            
            config.width = Int(rect.width * scale)
            config.height = Int(rect.height * scale)
            config.scalesToFit = true
            
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return NSImage(cgImage: cgImage, size: rect.size)
        } catch {
            print("[SnapshotDebug] SCK Capture Error: \(error)")
            return nil
        }
    }

    // Refactored: Returns AXUIElement instead of NSImage to allow async processing
    private func scanAndDismiss(_ root: AXUIElement) -> (title: String, body: String, appName: String, profileElement: AXUIElement?) {
        var titles: [String] = []
        var detectedAppName: String = "System"
        var candidateProfileElement: AXUIElement? = nil
        var pendingDismissal: (() -> Void)? = nil

        var windowTitle: AnyObject?
        AXUIElementCopyAttributeValue(root, kAXTitleAttribute as CFString, &windowTitle)
        if let wTitle = windowTitle as? String {
             print("[TreeDebug] Root Window Title: '\(wTitle)'")
            if wTitle != "Notification Center" && wTitle != "Window" && !wTitle.isEmpty {
                 detectedAppName = wTitle
            }
        }

        func crawl(_ el: AXUIElement, depth: Int) {
            if depth > 10 { return }

            var children: AnyObject?
            let res = AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
            guard res == .success, let list = children as? [AXUIElement] else { return }

            for child in list {
                // 1. Role
                var role: AnyObject?
                AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
                let roleStr = role as? String ?? "Unknown"
                
                var subrole: AnyObject?
                AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subrole)
                let subroleStr = subrole as? String ?? "Unknown"

                // --- TREE DEBUG PRINT ---
                // This will help us find where the profile image is hiding!
                print("[TreeDebug] Depth: \(depth) | Role: \(roleStr) | Subrole: \(subroleStr)")

                // 2. Text
                if roleStr == "AXStaticText" {
                    var val: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &val)
                    if let text = val as? String, !text.isEmpty {
                        print("[TreeDebug]    -> Text: \(text)")
                        titles.append(text)
                    }
                }
                
                // 3. App Name & Profile Photo Strategy
                if roleStr == "AXImage" {
                    var desc: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &desc)
                    let descStr = (desc as? String) ?? ""
                    
                    print("[TreeDebug]    -> Image Desc: '\(descStr)'")
                    
                    // Logic: If the image description matches the App Name, it's likely the App Icon.
                    // If it does NOT match, it is a strong candidate for a profile photo.
                    if !descStr.isEmpty && detectedAppName != "System" && descStr.localizedCaseInsensitiveContains(detectedAppName) {
                        print("[SnapshotDebug] -> Matches AppName. Likely App Icon.")
                    } else {
                        // Candidate for Profile Photo
                        // We store the first valid candidate we find
                        if candidateProfileElement == nil {
                            print("[SnapshotDebug] -> Candidate found (AXImage)")
                            candidateProfileElement = child
                        }
                    }
                    
                    // Fallback App Name detection
                    if !descStr.isEmpty {
                        if detectedAppName == "System" { detectedAppName = descStr }
                    }
                }
                
                if roleStr == "AXButton" {
                    var desc: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &desc)
                    let descStr = (desc as? String) ?? ""
                    
                    if !descStr.isEmpty && !["Close", "Clear", "Actions", "Reply", "Mute"].contains(descStr) {
                         // Potentially update app name if we haven't found one
                         if detectedAppName == "System" { detectedAppName = descStr }
                    }
                }
                
                if roleStr == "AXGroup" {
                    var desc: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &desc)
                    if let descStr = desc as? String, !descStr.isEmpty {
                        print("[TreeDebug]    -> Group Desc: \(descStr)")
                        if descStr.hasPrefix("Notification from ") {
                            detectedAppName = String(descStr.dropFirst(18))
                        } else if descStr.contains(", ") {
                            let components = descStr.components(separatedBy: ", ")
                            if let first = components.first, !first.isEmpty { detectedAppName = first }
                        }
                    }
                }

                // 4. Dismissal
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
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { dismissal() }
        }
        
        let t = titles.first ?? "New Notification"
        let b = titles.count > 1 ? titles[1] : ""
        return (t, b, detectedAppName, candidateProfileElement)
    }
}

import Foundation
import ApplicationServices
import Cocoa
import Combine
import ScreenCaptureKit

struct CapturedNotification: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let body: String
    let appName: String
    let icon: NSImage?
    let profileImage: NSImage?
    let dismissAction: (() -> Void)?
    let timestamp = Date()
    
    static func == (lhs: CapturedNotification, rhs: CapturedNotification) -> Bool {
        return lhs.id == rhs.id
    }
}

func observerCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let monitor = Unmanaged<NotificationMonitor>.fromOpaque(refcon).takeUnretainedValue()
    
    let notifName = notification as String
    print("[Monitor] ⚡️ AXObserver Callback Fired: \(notifName)")
    
    DispatchQueue.global(qos: .userInteractive).async {
        // Reduced delay to catch rapid updates, but kept slight pause for rendering
        usleep(50000) // 50ms
        monitor.handleNewNotification(element: element)
    }
}

class NotificationMonitor: ObservableObject {
    public let notificationSubject = PassthroughSubject<CapturedNotification, Never>()
    
    @Published var permissionGranted: Bool = false
    @Published var isListening: Bool = false
    @Published var errorMessage: String? = nil
    
    private var observer: AXObserver?
    
    // De-duplication state
    private var lastCapturedSignature: String = ""
    private var lastCapturedTime: Date = Date.distantPast
    
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
        
        // Listen for Window Creation (Standard banners)
        AXObserverAddNotification(axObserver, appElement, kAXWindowCreatedNotification as CFString, selfPointer)
        
        // Listen for Element Creation (Rapid banners that might reuse windows or append to list)
        // Fixed: Use kAXCreatedNotification instead of the incorrect kAXUIElementCreatedNotification
        AXObserverAddNotification(axObserver, appElement, kAXCreatedNotification as CFString, selfPointer)
        
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
        // Climb up to find the root window or container.
        // If 'element' is just a text field that triggered 'Created', we need its parent window to find the other text/buttons.
        let rootElement = getTopLevelParent(element)
        performScan(element: rootElement, retryCount: 0)
    }
    
    private func getTopLevelParent(_ element: AXUIElement) -> AXUIElement {
        var current = element
        // Climb up max 5 levels to find a Window or top-level Group
        for _ in 0..<5 {
            var role: AnyObject?
            AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role)
            if let r = role as? String, r == "AXWindow" {
                return current
            }
            
            var parent: AnyObject?
            let result = AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent)
            if result != .success || parent == nil {
                break
            }
            // Use force cast carefully, knowing AX APIs return CFTypes compatible with AXUIElement
            current = parent as! AXUIElement
        }
        return current
    }
    
    private func performScan(element: AXUIElement, retryCount: Int) {
        let content = scanAndDismiss(element)
        
        // Success case: We found text
        if !content.title.isEmpty || !content.body.isEmpty {
            
            // DE-DUPLICATION CHECK
            let signature = "\(content.appName)|\(content.title)|\(content.body)"
            let now = Date()
            if signature == lastCapturedSignature && now.timeIntervalSince(lastCapturedTime) < 2.0 {
                print("[Monitor] ♻️ Duplicate detected within 2s. Ignoring.")
                return
            }
            
            // Update cache
            lastCapturedSignature = signature
            lastCapturedTime = now
            
            let icon = resolveAppIcon(appName: content.appName)
            
            Task {
                var profileImg: NSImage? = nil
                if let profileElement = content.profileElement {
                    profileImg = await captureSnapshot(of: profileElement)
                }
                
                let finalNotification = CapturedNotification(
                    title: content.title,
                    body: content.body,
                    appName: content.appName,
                    icon: icon,
                    profileImage: profileImg,
                    dismissAction: content.dismissAction
                )
                
                print("[Monitor] 📤 Sending: \(finalNotification.title)")
                notificationSubject.send(finalNotification)
            }
        }
        else {
            if retryCount < 3 {
                // Short retry delay
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    self.performScan(element: element, retryCount: retryCount + 1)
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
    
    private func getElementFrame(_ element: AXUIElement) -> CGRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        
        var position = CGPoint.zero
        var size = CGSize.zero
        
        if let pos = posValue { AXValueGetValue(pos as! AXValue, .cgPoint, &position) }
        else { return nil }
        
        if let sz = sizeValue { AXValueGetValue(sz as! AXValue, .cgSize, &size) }
        else { return nil }
        
        return CGRect(origin: position, size: size)
    }
    
    private func captureSnapshot(of element: AXUIElement) async -> NSImage? {
        guard let rect = getElementFrame(element) else { return nil }
        if rect.width < 10 || rect.height < 10 { return nil }
        return await captureRect(rect)
    }
    
    @available(macOS 14.0, *)
    private func captureRect(_ rect: CGRect) async -> NSImage? {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first(where: { $0.frame.intersects(rect) }) else { return nil }
            
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            
            let localOrigin = CGPoint(x: rect.minX - display.frame.minX, y: rect.minY - display.frame.minY)
            let localRect = CGRect(origin: localOrigin, size: rect.size)
            
            config.sourceRect = localRect
            config.showsCursor = false
            
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
            // print("Snapshot Capture Error: \(error)")
            return nil
        }
    }

    private func scanAndDismiss(_ root: AXUIElement) -> (title: String, body: String, appName: String, profileElement: AXUIElement?, dismissAction: (() -> Void)?) {
        var titles: [String] = []
        var detectedAppName: String = "System"
        var candidateProfileElement: AXUIElement? = nil
        var pendingDismissal: (() -> Void)? = nil
        var isHistoryPanel = false

        var windowTitle: AnyObject?
        AXUIElementCopyAttributeValue(root, kAXTitleAttribute as CFString, &windowTitle)
        if let wTitle = windowTitle as? String {
            if wTitle != "Notification Center" && wTitle != "Window" && !wTitle.isEmpty {
                 detectedAppName = wTitle
            }
        }

        func crawl(_ el: AXUIElement, depth: Int) {
            if depth > 10 || isHistoryPanel { return }

            var children: AnyObject?
            let res = AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
            guard res == .success, let list = children as? [AXUIElement] else { return }

            for child in list {
                var role: AnyObject?
                AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
                let roleStr = role as? String ?? "Unknown"
                
                var subrole: AnyObject?
                AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subrole)
                let subroleStr = subrole as? String ?? ""

                // 2. Text (Expanded Roles)
                if roleStr == "AXStaticText" || roleStr == "AXTextArea" || roleStr == "AXTextField" {
                    var val: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &val)
                    if let text = val as? String, !text.isEmpty {
                        let t = text.lowercased()
                        if t == "notification center" ||
                           t == "no notifications" ||
                           t == "do not disturb" ||
                           t == "edit widgets" ||
                           t == "widgets" {
                            isHistoryPanel = true
                            return
                        }
                        titles.append(text)
                    }
                }
                
                // 3. App Name & Profile Photo Strategy
                if roleStr == "AXImage" {
                    var desc: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &desc)
                    let descStr = (desc as? String) ?? ""
                    
                    if !descStr.isEmpty && detectedAppName != "System" && descStr.localizedCaseInsensitiveContains(detectedAppName) {
                        // Likely App Icon
                    } else {
                        if candidateProfileElement == nil { candidateProfileElement = child }
                    }
                    if !descStr.isEmpty { if detectedAppName == "System" { detectedAppName = descStr } }
                }
                
                if roleStr == "AXButton" {
                    var desc: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &desc)
                    let descStr = (desc as? String) ?? ""
                    
                    if descStr == "Clear" || descStr == "Clear All" {
                        isHistoryPanel = true
                        return
                    }
                    
                    if !descStr.isEmpty && !["Close", "Clear", "Actions", "Reply", "Mute"].contains(descStr) {
                         if detectedAppName == "System" { detectedAppName = descStr }
                    }
                }
                
                if roleStr == "AXGroup" {
                    var desc: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &desc)
                    if let descStr = desc as? String, !descStr.isEmpty {
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
        
        if isHistoryPanel {
            return ("", "", "", nil, nil)
        }

        let t = titles.first ?? "New Notification"
        if t == "Notification Center" {
            return ("", "", "", nil, nil)
        }
        
        // Relaxed dismissal check: allow read-only
        
        let b = titles.count > 1 ? titles[1] : ""
        return (t, b, detectedAppName, candidateProfileElement, pendingDismissal)
    }
}

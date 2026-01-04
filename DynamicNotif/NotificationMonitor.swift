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
    let otpCode: String?
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
    print("[Monitor] ⚡️ AXObserver Callback Fired: \(notifName) (Thread: \(Thread.current.isMainThread ? "Main" : "Bg"))")
    
    DispatchQueue.global(qos: .userInteractive).async {
        usleep(100000) // 100ms delay to allow UI updates
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
    private var capturedSignatures: [String: Date] = [:]
    private let dedupeLock = NSLock() // Lock to prevent race conditions
    
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
        
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            
            guard let pid = self.findNotificationCenterPID() else {
                print("❌ Could not find Notification Center PID")
                DispatchQueue.main.async { self.errorMessage = "Could not find 'NotificationCenter'." }
                return
            }
            
            print("✅ Found Notification Center PID: \(pid)")
            
            let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            
            var newObserver: AXObserver?
            guard AXObserverCreate(pid, observerCallback, &newObserver) == .success, let axObserver = newObserver else {
                print("❌ Failed to create AXObserver")
                return
            }
            
            self.observer = axObserver
            
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
            
            let appElement = AXUIElementCreateApplication(pid)
            
            // 1. Standard Window Creation
            AXObserverAddNotification(axObserver, appElement, kAXWindowCreatedNotification as CFString, selfPointer)
            
            // 2. Element Creation (Rapid banners / List items)
            AXObserverAddNotification(axObserver, appElement, kAXCreatedNotification as CFString, selfPointer)
            
            // 3. Value Changed (Window Reuse: Text updates in existing banner)
            AXObserverAddNotification(axObserver, appElement, kAXValueChangedNotification as CFString, selfPointer)
            
            // 4. Layout Changed (General updates)
            AXObserverAddNotification(axObserver, appElement, kAXLayoutChangedNotification as CFString, selfPointer)
            
            // 5. Window Moved (Sliding animation completion might trigger this)
            AXObserverAddNotification(axObserver, appElement, kAXWindowMovedNotification as CFString, selfPointer)
            
            DispatchQueue.main.async { self.isListening = true }
            
            print("[Monitor] 🚀 Background RunLoop Started for AXObserver")
            CFRunLoopRun()
        }
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
        let rootElement = getTopLevelParent(element)
        performScan(element: rootElement, retryCount: 0)
    }
    
    private func getTopLevelParent(_ element: AXUIElement) -> AXUIElement {
        var current = element
        for _ in 0..<5 {
            var role: AnyObject?
            AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role)
            if let r = role as? String, r == "AXWindow" { return current }
            if let r = role as? String, r == "AXApplication" { return current }
            
            var parent: AnyObject?
            let result = AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent)
            if result != .success || parent == nil { break }
            current = parent as! AXUIElement
        }
        return current
    }
    
    private func performScan(element: AXUIElement, retryCount: Int) {
        let content = scanAndDismiss(element)
        
        if !content.title.isEmpty || !content.body.isEmpty {
            
            // SIMPLIFIED SIGNATURE: Exclude AppName to avoid duplicates when AppName detection flaps (e.g. "Script Editor" vs "System")
            let signature = "\(content.title)|\(content.body)"
            let now = Date()
            
            // THREAD-SAFE DEDUPLICATION
            dedupeLock.lock()
            
            // 1. Cleanup: Remove signatures older than 10 seconds to keep memory check fast
            capturedSignatures = capturedSignatures.filter { now.timeIntervalSince($0.value) < 10.0 }
            
            // 2. Check: If we saw this exact content less than 5 seconds ago, ignore it.
            if let lastTime = capturedSignatures[signature], now.timeIntervalSince(lastTime) < 5.0 {
                print("[Monitor] ♻️ Duplicate content (Time delta: \(String(format: "%.2f", now.timeIntervalSince(lastTime)))s). Ignoring signature: \(signature.prefix(30))...")
                dedupeLock.unlock()
                return
            }
            
            // 3. Update
            capturedSignatures[signature] = now
            dedupeLock.unlock()
            
            let icon = resolveAppIcon(appName: content.appName)
            let otp = extractOTP(from: content.body) ?? extractOTP(from: content.title)
            
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
                    otpCode: otp,
                    dismissAction: content.dismissAction
                )
                
                print("[Monitor] 📤 Captured & Sending: \(finalNotification.title) (OTP: \(otp ?? "None"))")
                notificationSubject.send(finalNotification)
            }
        }
        else {
            if retryCount < 3 {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                    self.performScan(element: element, retryCount: retryCount + 1)
                }
            }
        }
    }
    
    private func extractOTP(from text: String) -> String? {
        let pattern = "(?<!\\d)(\\d{4,8}|\\d{3}-\\d{3})(?!\\d)"
        
        do {
            let regex = try NSRegularExpression(pattern: pattern)
            let nsString = text as NSString
            let results = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
            
            for match in results {
                let foundString = nsString.substring(with: match.range)
                if let num = Int(foundString), num >= 2000 && num <= 2030 { continue }
                return foundString
            }
        } catch {
            print("Regex Error: \(error)")
        }
        return nil
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
                
                if roleStr == "AXTable" || roleStr == "AXOutline" || roleStr == "AXList" {
                    isHistoryPanel = true
                    return
                }
                
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

        let t = titles.first ?? ""
        if t == "Notification Center" {
            return ("", "", "", nil, nil)
        }
        
        let b = titles.count > 1 ? titles[1] : ""
        return (t, b, detectedAppName, candidateProfileElement, pendingDismissal)
    }
}

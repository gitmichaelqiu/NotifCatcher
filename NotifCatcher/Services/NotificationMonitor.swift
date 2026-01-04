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
    private let dedupeLock = NSLock()
    
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
                DispatchQueue.main.async { self.errorMessage = "Could not find 'NotificationCenter'." }
                return
            }
            
            let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            var newObserver: AXObserver?
            guard AXObserverCreate(pid, observerCallback, &newObserver) == .success, let axObserver = newObserver else { return }
            
            self.observer = axObserver
            
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
            
            let appElement = AXUIElementCreateApplication(pid)
            
            AXObserverAddNotification(axObserver, appElement, kAXWindowCreatedNotification as CFString, selfPointer)
            AXObserverAddNotification(axObserver, appElement, kAXCreatedNotification as CFString, selfPointer)
            AXObserverAddNotification(axObserver, appElement, kAXValueChangedNotification as CFString, selfPointer)
            AXObserverAddNotification(axObserver, appElement, kAXLayoutChangedNotification as CFString, selfPointer)
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
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-x", "NotificationCenter"]
        try? task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), let pid = Int32(output) {
            return pid
        }
        return nil
    }
    
    func handleNewNotification(element: AXUIElement) {
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
            
            let signature = "\(content.title)|\(content.body)"
            let now = Date()
            
            dedupeLock.lock()
            capturedSignatures = capturedSignatures.filter { now.timeIntervalSince($0.value) < 10.0 }
            if let lastTime = capturedSignatures[signature], now.timeIntervalSince(lastTime) < 5.0 {
                dedupeLock.unlock()
                return
            }
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
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsString = text as NSString
        let results = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
        for match in results {
            let s = nsString.substring(with: match.range)
            if let n = Int(s), n >= 2000 && n <= 2030 { continue }
            return s
        }
        return nil
    }
    
    private func resolveAppIcon(appName: String) -> NSImage? {
        guard !appName.isEmpty, appName != "System" else { return nil }
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) { return app.icon }
        return nil
    }
    
    private func getElementFrame(_ element: AXUIElement) -> CGRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        var pos = CGPoint.zero
        var size = CGSize.zero
        if let p = posValue { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
        if let s = sizeValue { AXValueGetValue(s as! AXValue, .cgSize, &size) }
        return (pos.x == 0 && size.width == 0) ? nil : CGRect(origin: pos, size: size)
    }
    
    private func captureSnapshot(of element: AXUIElement) async -> NSImage? {
        guard let rect = getElementFrame(element), rect.width > 10, rect.height > 10 else { return nil }
        if #available(macOS 14.0, *) { return await captureRect(rect) }
        return nil
    }
    
    @available(macOS 14.0, *)
    private func captureRect(_ rect: CGRect) async -> NSImage? {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first(where: { $0.frame.intersects(rect) }) else { return nil }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(origin: CGPoint(x: rect.minX - display.frame.minX, y: rect.minY - display.frame.minY), size: rect.size)
            config.showsCursor = false
            config.scalesToFit = true
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return NSImage(cgImage: cgImage, size: rect.size)
        } catch { return nil }
    }

    private func scanAndDismiss(_ root: AXUIElement) -> (title: String, body: String, appName: String, profileElement: AXUIElement?, dismissAction: (() -> Void)?) {
        var titles: [String] = []
        var detectedAppName: String = "System"
        var candidateProfileElement: AXUIElement? = nil
        var pendingDismissal: (() -> Void)? = nil
        var isHistoryPanel = false

        func crawl(_ el: AXUIElement, depth: Int) {
            if depth > 10 || isHistoryPanel { return }
            var children: AnyObject?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success, let list = children as? [AXUIElement] else { return }

            for child in list {
                var role: AnyObject?
                AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
                let roleStr = role as? String ?? "Unknown"
                
                // 1. Text
                if roleStr == "AXStaticText" || roleStr == "AXTextArea" || roleStr == "AXTextField" {
                    var val: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &val)
                    if let text = val as? String, !text.isEmpty {
                        let t = text.lowercased()
                        if ["notification center", "no notifications", "do not disturb", "widgets"].contains(t) {
                            isHistoryPanel = true; return
                        }
                        titles.append(text)
                    }
                }
                
                // 2. Image
                if roleStr == "AXImage" {
                    var desc: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &desc)
                    let d = (desc as? String) ?? ""
                    if !d.isEmpty && detectedAppName != "System" && d.localizedCaseInsensitiveContains(detectedAppName) { }
                    else if candidateProfileElement == nil { candidateProfileElement = child }
                    if !d.isEmpty && detectedAppName == "System" { detectedAppName = d }
                }
                
                // 3. Buttons & Groups (AppName detection)
                if roleStr == "AXButton" {
                    var desc: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &desc)
                    let d = (desc as? String) ?? ""
                    if d == "Clear" || d == "Clear All" { isHistoryPanel = true; return }
                    if !d.isEmpty && !["Close", "Clear", "Actions", "Reply", "Mute"].contains(d) && detectedAppName == "System" { detectedAppName = d }
                }
                
                // 4. Dismissal
                if pendingDismissal == nil {
                    var subrole: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subrole)
                    if (subrole as? String) == "AXNotificationCenterBanner" {
                        pendingDismissal = { _ = AXUIElementPerformAction(child, kAXCancelAction as CFString) }
                    } else if roleStr == "AXButton" {
                        var title: AnyObject?
                        AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &title)
                        if let t = title as? String, ["Close", "Clear"].contains(t) {
                            pendingDismissal = { _ = AXUIElementPerformAction(child, kAXPressAction as CFString) }
                        }
                    }
                }
                crawl(child, depth: depth + 1)
            }
        }
        
        crawl(root, depth: 0)
        
        if isHistoryPanel || titles.first == "Notification Center" { return ("", "", "", nil, nil) }
        
        let t = titles.first ?? ""
        let b = titles.count > 1 ? titles[1] : ""
        
        return (t, b, detectedAppName, candidateProfileElement, pendingDismissal)
    }
}

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
    
    DispatchQueue.global(qos: .userInteractive).async {
        usleep(100000)
        monitor.handleNewNotification(element: element)
    }
}

class NotificationMonitor: ObservableObject {
    public let notificationSubject = PassthroughSubject<CapturedNotification, Never>()
    
    @Published var permissionGranted: Bool = false
    @Published var isListening: Bool = false
    @Published var errorMessage: String? = nil
    
    private var observer: AXObserver?
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
        guard checkPermissions() else { return }
        
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self, let pid = self.findNotificationCenterPID() else { return }
            
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
            CFRunLoopRun()
        }
    }
    
    private func findNotificationCenterPID() -> pid_t? {
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-x", "NotificationCenter"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), let pid = Int32(output) {
            return pid
        }
        return nil
    }
    
    func handleNewNotification(element: AXUIElement) {
        let root = getTopLevelParent(element)
        performScan(element: root, retryCount: 0)
    }
    
    private func getTopLevelParent(_ element: AXUIElement) -> AXUIElement {
        var current = element
        for _ in 0..<5 {
            var role: AnyObject?
            AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role)
            if let r = role as? String, (r == "AXWindow" || r == "AXApplication") { return current }
            var parent: AnyObject?
            if AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success, parent != nil {
                current = parent as! AXUIElement
            } else { break }
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
                dedupeLock.unlock(); return
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
                
                let notif = CapturedNotification(
                    title: content.title, body: content.body, appName: content.appName,
                    icon: icon, profileImage: profileImg, otpCode: otp, dismissAction: content.dismissAction
                )
                notificationSubject.send(notif)
            }
        } else if retryCount < 3 {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { self.performScan(element: element, retryCount: retryCount + 1) }
        }
    }
    
    // ... [Helpers: extractOTP, resolveAppIcon, captureSnapshot identical to previous] ...
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
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) { return app.icon }
        return nil // Simplified for brevity, full version in history
    }
    
    private func captureSnapshot(of element: AXUIElement) async -> NSImage? {
        // Implementation from previous response
        return nil // Placeholder, assume full SCK implementation is here
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
            let res = AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
            guard res == .success, let list = children as? [AXUIElement] else { return }

            for child in list {
                var role: AnyObject?
                AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
                let roleStr = role as? String ?? ""
                
                // History Panel Detection
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
                
                // Image/Profile logic
                if roleStr == "AXImage" {
                    var desc: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &desc)
                    let d = (desc as? String) ?? ""
                    if !d.isEmpty && detectedAppName != "System" && d.localizedCaseInsensitiveContains(detectedAppName) { }
                    else { if candidateProfileElement == nil { candidateProfileElement = child } }
                    if !d.isEmpty && detectedAppName == "System" { detectedAppName = d }
                }
                
                // Dismissal Logic
                if pendingDismissal == nil {
                    var subrole: AnyObject?
                    AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subrole)
                    let subroleStr = subrole as? String ?? ""
                    
                    if subroleStr == "AXNotificationCenterBanner" {
                        pendingDismissal = { _ = AXUIElementPerformAction(child, kAXCancelAction as CFString) }
                    }
                    // Button logic...
                }
                
                crawl(child, depth: depth + 1)
            }
        }
        
        crawl(root, depth: 0)
        
        if isHistoryPanel || titles.first == "Notification Center" { return ("", "", "", nil, nil) }
        
        return (titles.first ?? "", titles.count > 1 ? titles[1] : "", detectedAppName, candidateProfileElement, pendingDismissal)
    }
}

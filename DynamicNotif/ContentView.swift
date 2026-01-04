import SwiftUI
import AppKit
import Combine

// MARK: - Main Control Panel (Settings Window)
struct ContentView: View {
    @StateObject var monitor = NotificationMonitor()
    @StateObject var windowManager = FloatingNotificationManager()
    
    // Debug Logging State
    @State private var testLog: String = "Ready for testing..."
    @State private var receivedCount: Int = 0
    
    var body: some View {
        VStack(spacing: 20) {
            // --- Header Section ---
            VStack(spacing: 15) {
                ZStack {
                    Circle()
                        .fill(monitor.isListening ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                        .frame(width: 80, height: 80)
                    
                    Image(systemName: monitor.isListening ? "waveform.circle.fill" : "lock.slash.fill")
                        .font(.system(size: 36))
                        .foregroundColor(monitor.isListening ? .green : .red)
                        .symbolEffect(.bounce, value: monitor.isListening)
                }
                
                Text("DynamicNotif Controller")
                    .font(.title3.bold())
                    .fontDesign(.rounded)
                
                if !monitor.permissionGranted {
                    Text("Accessibility Permission Required")
                        .font(.caption)
                        .foregroundColor(.red)
                } else if !monitor.isListening {
                    Button("Start Daemon") { monitor.startMonitoring() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("Monitoring Active")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 20)
            
            Divider()
            
            // --- Test Module Section ---
            VStack(alignment: .leading, spacing: 10) {
                Text("Debug & Test Module")
                    .font(.headline)
                
                HStack {
                    Button("Send OTP") {
                        let code = Int.random(in: 100000...999999)
                        triggerSystemNotification(id: receivedCount + 1, delay: 0, body: "Your verification code is \(code)")
                    }
                    
                    Button("Burst (3x)") {
                        let base = receivedCount
                        triggerSystemNotification(id: base + 1, delay: 0.1)
                        triggerSystemNotification(id: base + 2, delay: 1.2)
                        triggerSystemNotification(id: base + 3, delay: 3.0)
                    }
                    
                    Button("Clear Log") {
                        testLog = ""
                        receivedCount = 0
                    }
                }
                
                ScrollView {
                    Text(testLog)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 120)
                .background(Color.black.opacity(0.8))
                .foregroundColor(.green)
                .cornerRadius(8)
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .frame(minWidth: 400, minHeight: 450)
        .onReceive(monitor.notificationSubject) { newNotif in
            print("[ContentView] ✅ Received: \(newNotif.title)")
            
            let time = Date().formatted(.dateTime.hour().minute().second())
            testLog = "[\(time)] RECV: \(newNotif.title)\n" + testLog
            receivedCount += 1
            
            windowManager.showNotification(newNotif)
        }
        .onAppear {
            if monitor.permissionGranted && !monitor.isListening {
                print("[ContentView] Auto-starting monitoring...")
                monitor.startMonitoring()
            }
        }
    }
    
    private func triggerSystemNotification(id: Int, delay: TimeInterval, body: String? = nil) {
        let title = "Test Msg #\(id)"
        let actualBody = body ?? "This is test notification number \(id) sent via command."
        
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            print("[Test] Triggering notification #\(id)")
            let script = "display notification \"\(actualBody)\" with title \"\(title)\""
            let process = Process()
            process.launchPath = "/usr/bin/osascript"
            process.arguments = ["-e", script]
            try? process.run()
            
            DispatchQueue.main.async {
                let time = Date().formatted(.dateTime.hour().minute().second())
                self.testLog = "[\(time)] SENT: \(title)\n" + self.testLog
            }
        }
    }
}

// MARK: - Floating Window Manager
class FloatingNotificationManager: ObservableObject {
    private var panel: NSPanel?
    private var currentNotificationId: UUID?
    
    private let windowWidth: CGFloat = 450
    private let windowHeight: CGFloat = 200
    
    init() {
        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.acceptsMouseMovedEvents = true
        
        p.orderOut(nil)
        p.ignoresMouseEvents = true
        p.alphaValue = 0
        
        self.panel = p
    }
    
    func showNotification(_ notification: CapturedNotification) {
        guard let panel = self.panel else { return }
        
        self.currentNotificationId = notification.id
        
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let rightPadding: CGFloat = -35
            
            let xPos = visibleFrame.maxX - windowWidth - rightPadding
            let yPos = visibleFrame.maxY - windowHeight
            
            panel.setFrame(NSRect(x: xPos, y: yPos, width: windowWidth, height: windowHeight), display: true)
        }
        
        let rootView = DynamicIslandContainer(notification: notification) { [weak self] dismissedId in
            self?.hidePanel(for: dismissedId)
        }
        
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        
        panel.contentView = hostingView
        
        panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: panel.frame.origin.y))
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
    }
    
    private func hidePanel(for id: UUID) {
        guard id == self.currentNotificationId else {
            print("[WindowManager] Ignoring hide request for old ID: \(id)")
            return
        }
        
        print("[WindowManager] Hiding panel and disabling clicks for ID: \(id)")
        guard let panel = self.panel else { return }
        
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        panel.orderOut(nil)
    }
}

// MARK: - Dynamic Island View
struct DynamicIslandContainer: View {
    let notification: CapturedNotification
    var onDismiss: (UUID) -> Void
    
    @State private var isExpanded: Bool = false
    @State private var isVisible: Bool = false
    @State private var eventMonitor: Any? = nil
    
    // UI State for Copy Action
    @State private var isCopied: Bool = false
    
    private let springAnim = Animation.interpolatingSpring(mass: 0.5, stiffness: 200, damping: 18, initialVelocity: 0.5)
    
    private let startWidth: CGFloat = 20
    private let startHeight: CGFloat = 0
    private let expandedWidth: CGFloat = 380
    private let expandedHeight: CGFloat = 84
    
    var body: some View {
        VStack {
            ZStack(alignment: .top) {
                LiquidMenubarShape(
                    bottomRadius: isExpanded ? 32 : 4,
                    flareRadius: isExpanded ? 15 : 2
                )
                .fill(.black)
                .shadow(color: .black.opacity(0.4), radius: 15, x: 0, y: 8)
                
                LiquidMenubarShape(
                    bottomRadius: isExpanded ? 32 : 4,
                    flareRadius: isExpanded ? 15 : 2
                )
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                
                HStack(spacing: 12) {
                    ZStack {
                        if let profile = notification.profileImage {
                            Image(nsImage: profile)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: isExpanded ? 38 : 0, height: isExpanded ? 38 : 0)
                                .clipShape(Circle())
                                .opacity(isExpanded ? 1 : 0)
                        } else if let appIcon = notification.icon {
                            Image(nsImage: appIcon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: isExpanded ? 38 : 0, height: isExpanded ? 38 : 0)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .opacity(isExpanded ? 1 : 0)
                        } else {
                            Circle()
                                .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .top, endPoint: .bottom))
                                .frame(width: isExpanded ? 38 : 0, height: isExpanded ? 38 : 0)
                                .opacity(isExpanded ? 1 : 0)
                            
                            Image(systemName: "bell.badge.fill")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 18, height: 18)
                                .foregroundColor(.white)
                                .opacity(isExpanded ? 1 : 0)
                        }
                    }
                    
                    if isExpanded {
                        // Dynamic Layout: If OTP exists, adjust spacing
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(notification.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                
                                if !notification.body.isEmpty {
                                    Text(notification.body)
                                        .font(.system(size: 13))
                                        .foregroundColor(.white.opacity(0.8))
                                        .lineLimit(notification.otpCode != nil ? 1 : 2) // Shorten text if OTP shown
                                }
                            }
                            
                            Spacer(minLength: 8)
                            
                            // OTP BUTTON
                            if let otp = notification.otpCode {
                                Button(action: {
                                    copyOTP(otp)
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                            .font(.system(size: 11, weight: .bold))
                                        Text(isCopied ? "Copied" : otp)
                                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    }
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 10)
                                    .background(isCopied ? Color.green : Color.white.opacity(0.2))
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                                .transition(.scale)
                            } else {
                                VStack(alignment: .trailing) {
                                    Text("Now")
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 14)
                .frame(height: isExpanded ? expandedHeight : startHeight, alignment: .top)
                .opacity(isExpanded ? 1 : 0)
            }
            .frame(width: isExpanded ? expandedWidth : startWidth,
                   height: isExpanded ? expandedHeight : startHeight)
            .opacity(isVisible ? 1 : 0)
            .onTapGesture {
                openApp()
            }
            .padding(.top, 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.trailing, 0)
        .id(notification.id)
        .onAppear {
            runPresentationSequence()
            
            self.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                if let window = event.window, window.level.rawValue == Int(CGWindowLevelForKey(.mainMenuWindow)) + 2 {
                    if event.scrollingDeltaY < -2.0 {
                        print("[GestureDebug] Dismissing due to swipe up (Manual Dismiss)")
                        dismissSequence(shouldCloseNative: false)
                        return nil
                    }
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = self.eventMonitor {
                NSEvent.removeMonitor(monitor)
                self.eventMonitor = nil
            }
        }
    }
    
    private func copyOTP(_ code: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        
        withAnimation { isCopied = true }
        
        // Haptic Feedback (System)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        
        // Dismiss after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            dismissSequence(shouldCloseNative: true)
        }
    }
    
    private func runPresentationSequence() {
        isVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(springAnim) {
                isExpanded = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            dismissSequence(shouldCloseNative: false)
        }
    }
    
    private func dismissSequence(shouldCloseNative: Bool) {
        print("[Island] Dismiss Sequence. Close Native: \(shouldCloseNative)")
        
        withAnimation(springAnim) {
            isExpanded = false
        }
        
        if shouldCloseNative {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                notification.dismissAction?()
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeIn(duration: 0.2)) {
                isVisible = false
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                onDismiss(notification.id)
            }
        }
    }
    
    private func openApp() {
        print("[Island] Opening app: \(notification.appName)")
        let workspace = NSWorkspace.shared
        
        if let path = workspace.fullPath(forApplication: notification.appName) {
            let url = URL(fileURLWithPath: path)
            workspace.open(url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else {
            workspace.launchApplication(notification.appName)
        }
        
        dismissSequence(shouldCloseNative: true)
    }
}

struct LiquidMenubarShape: Shape {
    var bottomRadius: CGFloat
    var flareRadius: CGFloat
    
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, flareRadius) }
        set {
            bottomRadius = newValue.first
            flareRadius = newValue.second
        }
    }
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let safeFlare = min(flareRadius, w / 2)
        let inset = safeFlare
        let bodyMinX = rect.minX + inset
        let bodyMaxX = rect.maxX - inset
        
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: bodyMinX, y: rect.minY + safeFlare), control: CGPoint(x: bodyMinX, y: rect.minY))
        path.addLine(to: CGPoint(x: bodyMinX, y: rect.maxY - bottomRadius))
        path.addQuadCurve(to: CGPoint(x: bodyMinX + bottomRadius, y: rect.maxY), control: CGPoint(x: bodyMinX, y: rect.maxY))
        path.addLine(to: CGPoint(x: bodyMaxX - bottomRadius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: bodyMaxX, y: rect.maxY - bottomRadius), control: CGPoint(x: bodyMaxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: bodyMaxX, y: rect.minY + safeFlare))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: bodyMaxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

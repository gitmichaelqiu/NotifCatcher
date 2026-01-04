import SwiftUI
import AppKit
import Combine

// MARK: - Main Control Panel (Settings Window)
struct ContentView: View {
    @StateObject var monitor = NotificationMonitor()
    @StateObject var windowManager = FloatingNotificationManager()
    
    var body: some View {
        VStack(spacing: 25) {
            Spacer()
            
            // Status Icon
            ZStack {
                Circle()
                    .fill(monitor.isListening ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                    .frame(width: 100, height: 100)
                
                Image(systemName: monitor.isListening ? "waveform.circle.fill" : "lock.slash.fill")
                    .font(.system(size: 44))
                    .foregroundColor(monitor.isListening ? .green : .red)
                    .symbolEffect(.bounce, value: monitor.isListening)
            }
            .padding(.bottom, 10)
            
            Text("DynamicNotif Controller")
                .font(.title2.bold())
                .fontDesign(.rounded)
            
            if !monitor.permissionGranted {
                VStack(spacing: 8) {
                    Text("Permission Required")
                        .font(.headline)
                        .foregroundColor(.red)
                    Text("Please grant Accessibility access in System Settings to allow notification capturing.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.05)))
            } else {
                VStack(spacing: 12) {
                    Text(monitor.isListening ? "Daemon is Active" : "Ready to Start")
                        .font(.headline)
                        .foregroundColor(monitor.isListening ? .primary : .secondary)
                    
                    Button(action: {
                        if !monitor.isListening {
                            monitor.startMonitoring()
                        }
                    }) {
                        Text(monitor.isListening ? "Running..." : "Start Dynamic Island")
                            .fontWeight(.semibold)
                            .frame(maxWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(monitor.isListening ? .green : .blue)
                    .disabled(monitor.isListening)
                    .controlSize(.large)
                    
                    if monitor.isListening {
                        Text("Minimize this window. The Island will appear at the top RIGHT of your screen.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
        }
        .frame(minWidth: 400, minHeight: 350)
        .onChange(of: monitor.latestNotification) { newValue in
            guard let newNotif = newValue else { return }
            print("[ContentView] Received: \(newNotif.title)")
            windowManager.showNotification(newNotif)
        }
        .onAppear {
            // Auto-start if permissions are already granted
            if monitor.permissionGranted && !monitor.isListening {
                print("[ContentView] Auto-starting monitoring...")
                monitor.startMonitoring()
            }
        }
    }
}

// MARK: - Floating Window Manager
class FloatingNotificationManager: ObservableObject {
    private var panel: NSPanel?
    private var currentNotificationId: UUID?
    
    // Config: Position logic for Top Right
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
        
        // Start hidden completely
        p.orderOut(nil)
        p.ignoresMouseEvents = true
        p.alphaValue = 0
        
        self.panel = p
    }
    
    func showNotification(_ notification: CapturedNotification) {
        guard let panel = self.panel else { return }
        
        // Update current ID. This invalidates any pending hide requests from previous notifications.
        self.currentNotificationId = notification.id
        
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let rightPadding: CGFloat = -35
            
            let xPos = visibleFrame.maxX - windowWidth - rightPadding
            let yPos = visibleFrame.maxY - windowHeight
            
            panel.setFrame(NSRect(x: xPos, y: yPos, width: windowWidth, height: windowHeight), display: true)
        }
        
        // Pass the specific ID to the dismissal closure
        let rootView = DynamicIslandContainer(notification: notification) { [weak self] dismissedId in
            self?.hidePanel(for: dismissedId)
        }
        
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        
        panel.contentView = hostingView
        
        // Ensure panel is active
        panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: panel.frame.origin.y)) // Ensure position is valid
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
    }
    
    private func hidePanel(for id: UUID) {
        // RACE CONDITION FIX:
        // Only hide if the notification requesting hide is still the current one.
        // If a new notification came in, currentNotificationId will be different, so we ignore this request.
        guard id == self.currentNotificationId else {
            print("[WindowManager] Ignoring hide request for old ID: \(id). Current: \(String(describing: currentNotificationId))")
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
    // Updated callback to include ID
    var onDismiss: (UUID) -> Void
    
    @State private var isExpanded: Bool = false
    @State private var isVisible: Bool = false
    @State private var eventMonitor: Any? = nil
    
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
                        VStack(alignment: .leading, spacing: 3) {
                            Text(notification.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            
                            if !notification.body.isEmpty {
                                Text(notification.body)
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.8))
                                    .lineLimit(2)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    if isExpanded {
                        VStack(alignment: .trailing) {
                            Text("Now")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
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

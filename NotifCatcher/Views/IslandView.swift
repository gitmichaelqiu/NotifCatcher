import SwiftUI
import AppKit
import Combine

// MARK: - Floating Window Manager
class FloatingNotificationManager: ObservableObject {
    private var panel: NSPanel?
    private var currentNotificationId: UUID?
    private var cancellables = Set<AnyCancellable>()
    private var settings: IslandSettingsManager
    
    // Optimal Dimensions
    private let baseWindowWidth: CGFloat = 450
    private let windowHeight: CGFloat = 200
    
    init(monitor: NotificationMonitor, settings: IslandSettingsManager) {
        self.settings = settings
        
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
        
        monitor.notificationSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notif in
                self?.showNotification(notif)
            }
            .store(in: &cancellables)
    }
    
    func showNotification(_ notification: CapturedNotification) {
        guard let panel = self.panel else { return }
        
        self.currentNotificationId = notification.id
        
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            
            // RESTORED ORIGINAL LOGIC:
            // Direct offset calculation without complex content-width math.
            // This relies on the user adjusting 'rightPadding' to visually align the window
            // containing the centered island content.
            let padding = CGFloat(settings.rightPadding)
            
            let xPos = visibleFrame.maxX - baseWindowWidth - padding
            let yPos = visibleFrame.maxY - windowHeight
            
            panel.setFrame(NSRect(x: xPos, y: yPos, width: baseWindowWidth, height: windowHeight), display: true)
        }
        
        let rootView = DynamicIslandContainer(notification: notification, settings: settings) { [weak self] dismissedId in
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
        guard id == self.currentNotificationId else { return }
        guard let panel = self.panel else { return }
        
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        panel.orderOut(nil)
    }
}

// MARK: - Visual Island Component
struct DynamicIslandContainer: View {
    let notification: CapturedNotification
    @ObservedObject var settings: IslandSettingsManager
    var onDismiss: (UUID) -> Void
    
    @State private var isExpanded: Bool = false
    @State private var isStashed: Bool = false
    @State private var isVisible: Bool = false
    @State private var isCopied: Bool = false
    @State private var eventMonitor: Any? = nil
    @State private var autoDismissTask: DispatchWorkItem?
    
    private let springAnim = Animation.interpolatingSpring(mass: 0.5, stiffness: 200, damping: 18, initialVelocity: 0.5)
    
    private let startWidth: CGFloat = 20
    private let expandedHeight: CGFloat = 84
    private let stashedSize: CGFloat = 46
    
    var currentWidth: CGFloat {
        if isStashed { return stashedSize }
        if isExpanded { return CGFloat(settings.width) }
        return startWidth
    }
    
    var currentHeight: CGFloat {
        if isStashed { return stashedSize }
        if isExpanded { return expandedHeight }
        return 0
    }
    
    var body: some View {
        VStack {
            ZStack(alignment: .top) {
                // Background & Border
                Group {
                    LiquidMenubarShape(
                        bottomRadius: isStashed ? 23 : (isExpanded ? 32 : 4),
                        flareRadius: isStashed ? 8 : (isExpanded ? 15 : 2)
                    )
                    .fill(.black)
                    .shadow(color: .black.opacity(0.4), radius: 15, x: 0, y: 8)
                    
                    LiquidMenubarShape(
                        bottomRadius: isStashed ? 23 : (isExpanded ? 32 : 4),
                        flareRadius: isStashed ? 8 : (isExpanded ? 15 : 2)
                    )
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                }
                
                // Content
                HStack(spacing: 12) {
                    // Icon
                    ZStack {
                        if let profile = notification.profileImage {
                            Image(nsImage: profile).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: (isExpanded || isStashed) ? 38 : 0, height: (isExpanded || isStashed) ? 38 : 0)
                                .clipShape(Circle())
                        } else if let appIcon = notification.icon {
                            Image(nsImage: appIcon).resizable().aspectRatio(contentMode: .fit)
                                .frame(width: (isExpanded || isStashed) ? 38 : 0, height: (isExpanded || isStashed) ? 38 : 0)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Circle().fill(.gray)
                                .frame(width: (isExpanded || isStashed) ? 38 : 0, height: (isExpanded || isStashed) ? 38 : 0)
                        }
                    }
                    .opacity((isExpanded || isStashed) ? 1 : 0)
                    .scaleEffect(isStashed ? 0.8 : 1.0)
                    
                    if isExpanded && !isStashed {
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
                                        .lineLimit(notification.otpCode != nil ? 1 : 2)
                                }
                            }
                            
                            Spacer(minLength: 8)
                            
                            // OTP Action Button
                            if let otp = notification.otpCode {
                                Button(action: { copyOTP(otp) }) {
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
                            } else {
                                VStack(alignment: .trailing) {
                                    Text("Now").font(.caption2).foregroundColor(.gray)
                                }
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .padding(.horizontal, isStashed ? 4 : 30)
                .padding(.top, isStashed ? 4 : 14)
                .frame(height: currentHeight, alignment: .top)
            }
            .frame(width: currentWidth, height: currentHeight)
            .opacity(isVisible ? 1 : 0)
            .onTapGesture {
                if isStashed { expandFromStash() } else { openApp() }
            }
            .onHover { if isStashed && $0 { expandFromStash() } }
            .padding(.top, 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.trailing, 0)
        .id(notification.id)
        .onAppear {
            runPresentationSequence()
            setupScrollMonitor()
        }
        .onDisappear {
            if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
            autoDismissTask?.cancel()
        }
    }
    
    private func setupScrollMonitor() {
        self.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            if let window = event.window, window.level.rawValue == Int(CGWindowLevelForKey(.mainMenuWindow)) + 2 {
                if event.scrollingDeltaY < -2.0 && !isStashed { dismissSequence(shouldCloseNative: false); return nil }
                if event.scrollingDeltaX > 2.0 && !isStashed { withAnimation(springAnim) { stashNotification() }; return nil }
            }
            return event
        }
    }
    
    private func runPresentationSequence() {
        isVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { withAnimation(springAnim) { isExpanded = true } }
        let task = DispatchWorkItem { if !self.isStashed { self.dismissSequence(shouldCloseNative: false) } }
        self.autoDismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.displayDuration, execute: task)
    }
    
    private func stashNotification() {
        autoDismissTask?.cancel()
        isStashed = true
        isExpanded = false
    }
    
    private func expandFromStash() {
        isStashed = false
        isExpanded = true
        let task = DispatchWorkItem { if !self.isStashed { self.dismissSequence(shouldCloseNative: false) } }
        self.autoDismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.displayDuration, execute: task)
    }
    
    private func dismissSequence(shouldCloseNative: Bool) {
        withAnimation(springAnim) { isExpanded = false; isStashed = false }
        if shouldCloseNative { DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { notification.dismissAction?() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeIn(duration: 0.2)) { isVisible = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onDismiss(notification.id) }
        }
    }
    
    private func copyOTP(_ code: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        withAnimation { isCopied = true }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismissSequence(shouldCloseNative: true) }
    }
    
    private func openApp() {
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

// MARK: - Shape
struct LiquidMenubarShape: Shape {
    var bottomRadius: CGFloat
    var flareRadius: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, flareRadius) }
        set { bottomRadius = newValue.first; flareRadius = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let safeFlare = min(flareRadius, rect.width / 2)
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

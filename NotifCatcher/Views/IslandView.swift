import SwiftUI
import AppKit
import Combine

// MARK: - Floating Window Manager
class FloatingNotificationManager: ObservableObject {
    // Two separate windows to avoid blocking screen space between Island and Stash
    private var activePanel: NSPanel?
    private var stashPanel: NSPanel?
    
    @Published var activeNotification: CapturedNotification?
    @Published var stashedNotifications: [CapturedNotification] = []
    
    private var cancellables = Set<AnyCancellable>()
    private var settings: IslandSettingsManager
    
    // Dimensions
    private let activeWindowWidth: CGFloat = 450
    private let activeWindowHeight: CGFloat = 200
    private let stashWindowWidth: CGFloat = 60
    private let stashWindowHeight: CGFloat = 500 // Tall strip for stack
    
    init(monitor: NotificationMonitor, settings: IslandSettingsManager) {
        self.settings = settings
        
        // 1. Active Panel (The Island)
        self.activePanel = createPanel(width: activeWindowWidth, height: activeWindowHeight)
        
        // 2. Stash Panel (The Stack on the right)
        self.stashPanel = createPanel(width: stashWindowWidth, height: stashWindowHeight)
        
        // Subscribe to Monitor
        monitor.notificationSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notif in
                self?.present(notif)
            }
            .store(in: &cancellables)
    }
    
    private func createPanel(width: CGFloat, height: CGFloat) -> NSPanel {
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
        p.ignoresMouseEvents = true
        p.alphaValue = 0
        return p
    }
    
    // MARK: - Logic
    
    func present(_ notification: CapturedNotification) {
        // If we already have an active one, stash the OLD one (auto-stash logic)
        // OR: Replace it? Let's replace it for now, user can manually stash.
        // Actually, better UX: If user hasn't dealt with current, stash it to make room for new.
        if let current = activeNotification {
            withAnimation {
                stashedNotifications.insert(current, at: 0)
            }
            updateStashWindow()
        }
        
        self.activeNotification = notification
        updateActiveWindow()
    }
    
    func stashActive() {
        guard let current = activeNotification else { return }
        
        withAnimation {
            stashedNotifications.insert(current, at: 0)
            activeNotification = nil
        }
        
        hideActiveWindow()
        updateStashWindow()
    }
    
    func unstash(id: UUID) {
        guard let index = stashedNotifications.firstIndex(where: { $0.id == id }) else { return }
        let item = stashedNotifications.remove(at: index)
        
        // If there is currently an active one, stash it back to index 0
        if let current = activeNotification {
            stashedNotifications.insert(current, at: 0)
        }
        
        activeNotification = item
        
        updateStashWindow()
        updateActiveWindow()
    }
    
    func dismissActive() {
        activeNotification = nil
        hideActiveWindow()
    }
    
    // MARK: - Window Updates
    
    private func updateActiveWindow() {
        guard let panel = activePanel, let notif = activeNotification else { return }
        
        // Position Logic
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let padding = CGFloat(settings.rightPadding)
            // Align visually based on settings
            let xPos = visibleFrame.maxX - activeWindowWidth - padding
            let yPos = visibleFrame.maxY - activeWindowHeight
            panel.setFrame(NSRect(x: xPos, y: yPos, width: activeWindowWidth, height: activeWindowHeight), display: true)
        }
        
        let rootView = DynamicIslandContainer(
            notification: notif,
            settings: settings,
            onStash: { [weak self] in self?.stashActive() },
            onDismiss: { [weak self] _ in self?.dismissActive() }
        )
        
        let hosting = NSHostingView(rootView: rootView)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        
        panel.contentView = hosting
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }
    
    private func hideActiveWindow() {
        guard let panel = activePanel else { return }
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    }
    
    private func updateStashWindow() {
        guard let panel = stashPanel else { return }
        
        if stashedNotifications.isEmpty {
            panel.ignoresMouseEvents = true
            panel.alphaValue = 0
            panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            return
        }
        
        // Position Stash Panel on the far right edge
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            // Fixed small gap from right edge
            let xPos = visibleFrame.maxX - stashWindowWidth - 5
            // Start from top
            let yPos = visibleFrame.maxY - stashWindowHeight
            panel.setFrame(NSRect(x: xPos, y: yPos, width: stashWindowWidth, height: stashWindowHeight), display: true)
        }
        
        let rootView = StashStackView(items: stashedNotifications) { [weak self] id in
            self?.unstash(id: id)
        }
        
        let hosting = NSHostingView(rootView: rootView)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        
        panel.contentView = hosting
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }
    
    // For Preview
    func triggerPreview() {
        let dummy = CapturedNotification(
            title: "Preview",
            body: "Adjusting settings...",
            appName: "NotifCatcher",
            icon: NSImage(systemSymbolName: "gear", accessibilityDescription: nil),
            profileImage: nil,
            otpCode: nil,
            dismissAction: nil
        )
        present(dummy)
    }
}

// MARK: - View: Active Island
struct DynamicIslandContainer: View {
    let notification: CapturedNotification
    @ObservedObject var settings: IslandSettingsManager
    var onStash: () -> Void
    var onDismiss: (UUID) -> Void
    
    @State private var isExpanded: Bool = false
    @State private var isVisible: Bool = false
    @State private var isCopied: Bool = false
    @State private var eventMonitor: Any? = nil
    @State private var autoDismissTask: DispatchWorkItem?
    
    private let springAnim = Animation.interpolatingSpring(mass: 0.5, stiffness: 200, damping: 18, initialVelocity: 0.5)
    private let startWidth: CGFloat = 20
    private let expandedHeight: CGFloat = 84
    
    var body: some View {
        VStack {
            ZStack(alignment: .top) {
                // Background
                Group {
                    LiquidMenubarShape(bottomRadius: isExpanded ? 32 : 4, flareRadius: isExpanded ? 15 : 2)
                        .fill(.black)
                        .shadow(color: .black.opacity(0.4), radius: 15, x: 0, y: 8)
                    LiquidMenubarShape(bottomRadius: isExpanded ? 32 : 4, flareRadius: isExpanded ? 15 : 2)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                }
                
                // Content
                HStack(spacing: 12) {
                    // Icon
                    ZStack {
                        if let profile = notification.profileImage {
                            Image(nsImage: profile).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: isExpanded ? 38 : 0, height: isExpanded ? 38 : 0)
                                .clipShape(Circle())
                        } else if let appIcon = notification.icon {
                            Image(nsImage: appIcon).resizable().aspectRatio(contentMode: .fit)
                                .frame(width: isExpanded ? 38 : 0, height: isExpanded ? 38 : 0)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Circle().fill(.gray).frame(width: isExpanded ? 38 : 0, height: isExpanded ? 38 : 0)
                        }
                    }
                    .opacity(isExpanded ? 1 : 0)
                    
                    if isExpanded {
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
                            if let otp = notification.otpCode {
                                Button(action: { copyOTP(otp) }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .bold))
                                        Text(isCopied ? "Copied" : otp).font(.system(size: 13, weight: .bold, design: .monospaced))
                                    }
                                    .padding(.vertical, 6).padding(.horizontal, 10)
                                    .background(isCopied ? Color.green : Color.white.opacity(0.2)).foregroundColor(.white).cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            } else {
                                VStack(alignment: .trailing) { Text("Now").font(.caption2).foregroundColor(.gray) }
                            }
                        }
                        // FIX: Changed transition to .move(edge: .top) for better collapse animation
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 14)
                .frame(height: isExpanded ? expandedHeight : 0, alignment: .top)
            }
            .frame(width: isExpanded ? CGFloat(settings.width) : startWidth,
                   height: isExpanded ? expandedHeight : 0)
            .opacity(isVisible ? 1 : 0)
            .onTapGesture { openApp() }
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
                // Swipe Up -> Dismiss
                if event.scrollingDeltaY < -2.0 {
                    dismissSequence(shouldCloseNative: false)
                    return nil
                }
                // Swipe Right -> Stash
                if event.scrollingDeltaX > 2.0 {
                    stashSequence()
                    return nil
                }
            }
            return event
        }
    }
    
    private func runPresentationSequence() {
        isVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { withAnimation(springAnim) { isExpanded = true } }
        
        let task = DispatchWorkItem { self.dismissSequence(shouldCloseNative: false) }
        self.autoDismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.displayDuration, execute: task)
    }
    
    private func stashSequence() {
        autoDismissTask?.cancel()
        withAnimation(springAnim) { isExpanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onStash() // Notify manager to move to stash stack
        }
    }
    
    private func dismissSequence(shouldCloseNative: Bool) {
        withAnimation(springAnim) { isExpanded = false }
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

// MARK: - View: Stash Stack (Pills)
struct StashStackView: View {
    let items: [CapturedNotification]
    var onUnstash: (UUID) -> Void
    
    var body: some View {
        VStack(spacing: 8) {
            ForEach(items.prefix(5)) { item in // Limit to 5 visible pills
                Button(action: { withAnimation { onUnstash(item.id) } }) {
                    ZStack {
                        Capsule()
                            .fill(.black)
                            .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                        
                        Capsule()
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                        
                        if let icon = item.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 22, height: 22)
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "bell.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

// MARK: - Shape (Existing)
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

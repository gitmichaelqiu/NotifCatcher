import SwiftUI
import AppKit
import Combine

// MARK: - Main Control Panel (Settings Window)
struct ContentView: View {
    @StateObject var monitor = NotificationMonitor()
    @StateObject var windowManager = FloatingNotificationManager()
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: monitor.permissionGranted ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 50))
                .foregroundColor(monitor.permissionGranted ? .green : .red)
                .padding(.bottom, 10)
            
            Text("Dynamic Island Service")
                .font(.title2.bold())
            
            if !monitor.permissionGranted {
                Text("Accessibility Permission Needed")
                    .foregroundColor(.secondary)
                Text("Grant access in System Settings to enable.")
                    .font(.caption)
                    .padding(.top, 5)
            } else {
                Text("Status: \(monitor.isListening ? "Active" : "Ready")")
                    .foregroundColor(.secondary)
                
                if !monitor.isListening {
                    Button("Start Daemon") { monitor.startMonitoring() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else {
                    Text("The Dynamic Island will appear floating on the desktop.")
                        .font(.caption)
                        .padding(.top)
                }
            }
            Spacer()
        }
        .frame(minWidth: 400, minHeight: 300)
        .onChange(of: monitor.latestNotification) { newValue in
            guard let newNotif = newValue else { return }
            print("[Debug] ContentView received notification: \(newNotif.title)")
            windowManager.showNotification(newNotif)
        }
    }
}

// MARK: - Floating Window Manager
class FloatingNotificationManager: ObservableObject {
    @Published var isPanelActive = false
    
    private var panel: NSPanel?
    private var hostingView: NSHostingView<DynamicIslandContainer>?
    private var currentNotificationId: UUID?
    
    // Window configuration constants
    private let windowWidth: CGFloat = 450
    private let windowHeight: CGFloat = 200
    
    init() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        // Use a very high window level to float above system notifications
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        self.panel = p
        print("[Debug] WindowManager initialized")
    }
    
    func showNotification(_ notification: CapturedNotification) {
        guard let panel = self.panel else { return }
        
        print("[Debug] showNotification called. ID: \(notification.id)")
        self.currentNotificationId = notification.id
        
        let rootView = DynamicIslandContainer(notification: notification) { [weak self] in
            print("[Debug] Callback: Container requested hide for ID: \(notification.id)")
            self?.hidePanel(for: notification.id)
        }
        
        // FIX: Always create a fresh NSHostingView to ensure lifecycle events trigger
        let newHostingView = NSHostingView(rootView: rootView)
        // Fix: NSHostingView IS an NSView, it doesn't have a 'view' property.
        newHostingView.wantsLayer = true
        newHostingView.layer?.backgroundColor = NSColor.clear.cgColor // Ensure transparency
        panel.contentView = newHostingView
        self.hostingView = newHostingView
        
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            // Position the window's top-right corner near the screen's top-right corner.
            // visibleFrame.maxX = Screen Right.
            // visibleFrame.maxY = Bottom of Menu Bar.
            let xPos = visibleFrame.maxX - windowWidth
            let yPos = visibleFrame.maxY - windowHeight
            
            panel.setFrameOrigin(NSPoint(x: xPos, y: yPos))
        }
        
        self.isPanelActive = true
        panel.orderFrontRegardless()
    }
    
    private func hidePanel(for id: UUID) {
        print("[Debug] hidePanel called for ID: \(id). Current: \(currentNotificationId?.uuidString ?? "nil")")
        guard currentNotificationId == id else { return }
        
        panel?.orderOut(nil)
        self.isPanelActive = false
        self.currentNotificationId = nil
        print("[Debug] Panel hidden successfully")
    }
}

// MARK: - Dynamic Island Container
struct DynamicIslandContainer: View {
    let notification: CapturedNotification
    var onDismiss: () -> Void
    
    @State private var islandState: IslandState = .idle
    @State private var viewOpacity: Double = 0.0
    
    enum IslandState {
        case idle
        case expanded
    }
    
    var isExpanded: Bool { islandState == .expanded }
    
    // Exact spring physics from reference
    private let openAnimation = Animation.interactiveSpring(response: 0.45, dampingFraction: 0.75, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.5, dampingFraction: 0.85, blendDuration: 0)
    
    // Geometry
    private var topRadius: CGFloat { isExpanded ? 18 : 6 }
    private var bottomRadius: CGFloat { isExpanded ? 22 : 14 }
    
    // Layout Constants
    private let expandedWidth: CGFloat = 350
    private let idleWidth: CGFloat = 120
    private let expandedHeight: CGFloat = 84
    private let edgePadding: CGFloat = 12 // Gap from screen edge
    
    var body: some View {
        // ZStack alignment .topTrailing to pin to the corner, allowing manual padding to control centering
        ZStack(alignment: .topTrailing) {
            Color.clear // Transparent background
            
            HStack(alignment: .center, spacing: 0) {
                // LEFT: App Icon
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: isExpanded ? 36 : 10, height: isExpanded ? 36 : 10)
                        .opacity(isExpanded ? 1 : 0)
                    
                    Image(systemName: "bell.badge.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                        .foregroundColor(.white)
                        .opacity(isExpanded ? 1 : 0)
                }
                .frame(width: isExpanded ? 46 : 0)
                .clipped()
                
                // CENTER: Text
                VStack(alignment: .leading, spacing: 3) {
                    Text(notification.title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .opacity(isExpanded ? 1 : 0)
                        .scaleEffect(isExpanded ? 1 : 0.8, anchor: .topLeading)
                    
                    if !notification.body.isEmpty {
                        Text(notification.body)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(2)
                            .opacity(isExpanded ? 1 : 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: isExpanded ? nil : 0)
                .opacity(isExpanded ? 1 : 0)
                
                // RIGHT: Timestamp
                if isExpanded {
                    Text("Now")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .padding(.leading, 8)
                }
            }
            .padding(.horizontal, isExpanded ? 14 : 0)
            .padding(.vertical, isExpanded ? 14 : 0)
            // STYLE OPTIMIZATION:
            // - Width grows from 120 -> 350
            // - Height grows from 0 -> 84
            .frame(width: isExpanded ? expandedWidth : idleWidth, height: isExpanded ? expandedHeight : 0)
            .background(
                ZStack {
                    // Main black background
                    Color.black
                    // Subtle border overlay
                    NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 6)
            )
            .clipShape(NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius))
            .padding(.top, 0) // Flush with menu bar
            // MATH FOR CENTERING GROWTH:
            // Center of expanded (350) is at: edgePadding + 175 = 187 from right.
            // Center of idle (120) must be at 187 from right.
            // So idle trailing padding = 187 - (120/2) = 187 - 60 = 127.
            .padding(.trailing, isExpanded ? edgePadding : (edgePadding + (expandedWidth - idleWidth) / 2))
            .onTapGesture {
                print("[Debug] User tapped notification")
                dismiss()
            }
        }
        .opacity(viewOpacity)
        .id(notification.id)
        .onAppear {
            print("[Debug] Container onAppear for ID: \(notification.id)")
            
            // 1. Fade In
            withAnimation(.easeIn(duration: 0.15)) {
                viewOpacity = 1.0
            }
            
            // 2. Expand
            // Small delay to ensure render loop catches up
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(openAnimation) {
                    islandState = .expanded
                }
            }
            
            // 3. Auto-dismiss
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                print("[Debug] Auto-dismiss timer fired for ID: \(notification.id)")
                dismiss()
            }
        }
    }
    
    private func dismiss() {
        print("[Debug] Dismiss animation started for ID: \(notification.id)")
        // 1. Shrink Animation
        withAnimation(closeAnimation) {
            islandState = .idle
        }
        
        // 2. Fade Out Animation
        withAnimation(.easeOut(duration: 0.25)) {
            viewOpacity = 0
        }
        
        // 3. Close Window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            onDismiss()
        }
    }
}

// MARK: - Notch Shape
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return path
    }
}

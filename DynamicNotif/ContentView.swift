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
    
    init() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
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
        
        let newHostingView = NSHostingView(rootView: rootView)
        panel.contentView = newHostingView
        self.hostingView = newHostingView
        
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            // Center the 400px window relative to where we want the notch center to be.
            // If we want the notch center to be ~200px from the right edge:
            // Right Edge X = visibleFrame.maxX
            // Window Width = 400.
            // X Pos = visibleFrame.maxX - 400.
            // This places the window content area [0...400]. Center is 200.
            // So the notification center will be at screen_right - 200px.
            let xPos = visibleFrame.maxX - 400
            let yPos = visibleFrame.maxY - 120
            
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
    private let openAnimation = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
    
    // Geometry
    private var topRadius: CGFloat { isExpanded ? 19 : 6 }
    private var bottomRadius: CGFloat { isExpanded ? 24 : 14 }
    
    var body: some View {
        // Alignment .top ensures horizontal centering relative to the window width
        ZStack(alignment: .top) {
            Color.clear
            
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
            // Start with a wider "seed" (120) so it doesn't look like a point source.
            // Height 0 ensures it emerges from the top edge.
            .frame(width: isExpanded ? 340 : 120, height: isExpanded ? 80 : 0)
            .background(
                Color.black
                    .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 5)
            )
            .clipShape(NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius))
            // BORDER FIX: Use overlay instead of strokeBorder
            .overlay(
                NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1.5)
            )
            .padding(.top, 0) // Flush with menu bar
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
            withAnimation(.easeIn(duration: 0.1)) {
                viewOpacity = 1.0
            }
            // 2. Expand
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                withAnimation(openAnimation) {
                    islandState = .expanded
                }
            }
            // 3. Timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                dismiss()
            }
        }
    }
    
    private func dismiss() {
        withAnimation(closeAnimation) {
            islandState = .idle
        }
        withAnimation(.easeOut(duration: 0.2)) {
            viewOpacity = 0
        }
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

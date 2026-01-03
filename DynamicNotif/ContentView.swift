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
            print("[ContentView] Icon status: \(newNotif.icon == nil ? "MISSING" : "FOUND")")
            // Trigger the Dynamic Island
            windowManager.showNotification(newNotif)
        }
    }
}

// MARK: - Floating Window Manager
class FloatingNotificationManager: ObservableObject {
    private var panel: NSPanel?
    private var currentNotificationId: UUID?
    
    // Config: Position logic for Top Right
    private let windowWidth: CGFloat = 400 // Slightly wider for banner look
    private let windowHeight: CGFloat = 200
    
    init() {
        // Create a transparent, borderless overlay window
        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], // critical for overlays
            backing: .buffered,
            defer: false
        )
        
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        // Level must be higher than the Menu Bar (Main Menu + 1) to cover native notifications
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.ignoresMouseEvents = false // Allow interaction
        
        self.panel = p
    }
    
    func showNotification(_ notification: CapturedNotification) {
        guard let panel = self.panel else { return }
        
        self.currentNotificationId = notification.id
        
        // 1. Position Window: Top Right
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            // X: Align to right edge (maxX)
            // We align it exactly to the right edge or with a tiny padding?
            // Usually banners have a small margin, but "attached" styles might touch the edge.
            // Let's stick to standard notification alignment: ~10px padding from right.
            let rightPadding: CGFloat = 10
            let xPos = visibleFrame.maxX - windowWidth - rightPadding
            
            // Y: Touch the Menu Bar.
            // visibleFrame.maxY is the bottom of the menu bar.
            // We want the window content to start exactly there.
            let yPos = visibleFrame.maxY - windowHeight
            
            panel.setFrame(NSRect(x: xPos, y: yPos, width: windowWidth, height: windowHeight), display: true)
        }
        
        // 2. Set Content
        let rootView = DynamicIslandContainer(notification: notification) { [weak self] in
            self?.hidePanel()
        }
        
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        
        panel.contentView = hostingView
        panel.orderFrontRegardless()
    }
    
    private func hidePanel() {
         // Panel hiding logic
    }
}

// MARK: - Dynamic Island View
struct DynamicIslandContainer: View {
    let notification: CapturedNotification
    var onDismiss: () -> Void
    
    // Animation States
    @State private var isExpanded: Bool = false
    @State private var isVisible: Bool = false
    
    // Physics Configuration (Bouncy Spring)
    // Using a slightly more responsive spring for the "pop" effect
    private let springAnim = Animation.interpolatingSpring(mass: 0.5, stiffness: 200, damping: 18, initialVelocity: 0.5)
    
    // Dimensions
    // Start State: Small invisible point at top center
    private let startWidth: CGFloat = 20
    private let startHeight: CGFloat = 0
    
    // Expanded: Full notification banner size
    private let expandedWidth: CGFloat = 360
    private let expandedHeight: CGFloat = 84
    
    var body: some View {
        VStack {
            // The Island
            ZStack(alignment: .top) {
                // Background with Custom Shape
                LiquidMenubarShape(
                    bottomRadius: isExpanded ? 32 : 4,
                    flareRadius: isExpanded ? 15 : 2 // Animate flare radius for smoothness
                )
                .fill(.black)
                .shadow(color: .black.opacity(0.4), radius: 15, x: 0, y: 8)
                
                // Border (Subtle shine)
                LiquidMenubarShape(
                    bottomRadius: isExpanded ? 32 : 4,
                    flareRadius: isExpanded ? 15 : 2
                )
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                
                // CONTENT LAYER
                HStack(spacing: 12) {
                    // LEFT: Icon
                    ZStack {
                        if let appIcon = notification.icon {
                            Image(nsImage: appIcon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: isExpanded ? 38 : 0, height: isExpanded ? 38 : 0)
                                // UPDATED: Rounded Square Shape for App Icon
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .opacity(isExpanded ? 1 : 0)
                        } else {
                            // Fallback Icon
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
                    
                    // CENTER: Text Info
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
                    
                    // RIGHT: Time/Close
                    if isExpanded {
                        VStack(alignment: .trailing) {
                            Text("Now")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .padding(.horizontal, 30) // Extra padding to clear the "flare"
                .padding(.top, 14) // Push down from menu bar
                .frame(height: isExpanded ? expandedHeight : startHeight, alignment: .top)
                .opacity(isExpanded ? 1 : 0)
            }
            // Dynamic Sizing
            // Alignment .top ensures it grows from the horizontal center
            .frame(width: isExpanded ? expandedWidth : startWidth,
                   height: isExpanded ? expandedHeight : startHeight)
            .opacity(isVisible ? 1 : 0)
            .onTapGesture {
                dismissSequence()
            }
            .padding(.top, 0) // Pin to very top (menu bar contact)
        }
        // ALIGNMENT: Top (Horizontal Center)
        // This makes the island grow symmetrically from the center of the window width
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.trailing, 0)
        .id(notification.id)
        .onAppear {
            runPresentationSequence()
        }
    }
    
    private func runPresentationSequence() {
        // 1. Initial State: Invisible
        isVisible = true
        
        // 2. Direct Expansion (Pop)
        // Small delay to ensure render cycle is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(springAnim) {
                isExpanded = true
            }
        }
        
        // 3. Auto Dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            dismissSequence()
        }
    }
    
    private func dismissSequence() {
        withAnimation(springAnim) {
            isExpanded = false
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeIn(duration: 0.2)) {
                isVisible = false
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                onDismiss()
            }
        }
    }
}

// MARK: - Custom Shape for "Attached" Look
// Creates a shape that looks like it flows out of the menu bar
struct LiquidMenubarShape: Shape {
    var bottomRadius: CGFloat
    var flareRadius: CGFloat // The "reversed" radius at top corners
    
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, flareRadius) }
        set {
            bottomRadius = newValue.first
            flareRadius = newValue.second
        }
    }
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        // Dimensions
        let w = rect.width
        let h = rect.height
        
        // Clamp flare radius to avoid crossing in middle when width is small
        let safeFlare = min(flareRadius, w / 2)
        
        let inset = safeFlare
        let bodyMinX = rect.minX + inset
        let bodyMaxX = rect.maxX - inset
        
        // Start Top Left (At Menu Bar, full width)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        
        // 1. Top Left Flare (Reversed/Concave Curve)
        path.addQuadCurve(
            to: CGPoint(x: bodyMinX, y: rect.minY + safeFlare),
            control: CGPoint(x: bodyMinX, y: rect.minY)
        )
        
        // 2. Left Edge
        path.addLine(to: CGPoint(x: bodyMinX, y: rect.maxY - bottomRadius))
        
        // 3. Bottom Left Corner (Standard Convex)
        path.addQuadCurve(
            to: CGPoint(x: bodyMinX + bottomRadius, y: rect.maxY),
            control: CGPoint(x: bodyMinX, y: rect.maxY)
        )
        
        // 4. Bottom Edge
        path.addLine(to: CGPoint(x: bodyMaxX - bottomRadius, y: rect.maxY))
        
        // 5. Bottom Right Corner (Standard Convex)
        path.addQuadCurve(
            to: CGPoint(x: bodyMaxX, y: rect.maxY - bottomRadius),
            control: CGPoint(x: bodyMaxX, y: rect.maxY)
        )
        
        // 6. Right Edge
        path.addLine(to: CGPoint(x: bodyMaxX, y: rect.minY + safeFlare))
        
        // 7. Top Right Flare (Reversed/Concave Curve)
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: bodyMaxX, y: rect.minY)
        )
        
        path.closeSubpath()
        
        return path
    }
}

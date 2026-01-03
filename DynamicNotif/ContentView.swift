import SwiftUI
import AppKit
import Combine

// MARK: - Main Control Panel (Settings Window)
struct ContentView: View {
    @StateObject var monitor = NotificationMonitor()
    // We move the window management to a specialized object
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
        // Connect the Monitor to the Window Manager
        .onChange(of: monitor.latestNotification) { newValue in
            guard let newNotif = newValue else { return }
            print("[Debug] ContentView received notification: \(newNotif.title)")
            windowManager.showNotification(newNotif)
        }
    }
}

// MARK: - Floating Window Manager (The "Hacker" Part)
class FloatingNotificationManager: ObservableObject {
    @Published var isPanelActive = false // Added to satisfy ObservableObject protocol requirements
    
    private var panel: NSPanel?
    private var hostingView: NSHostingView<DynamicIslandContainer>?
    private var currentNotificationId: UUID? // Fix: Track active ID to prevent race conditions
    
    init() {
        // Initialize panel directly in init to satisfy strict Swift initialization rules
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.borderless, .nonactivatingPanel], // No title bar, doesn't steal focus
            backing: .buffered,
            defer: false
        )
        
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.level = .floating // Float above normal windows
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        self.panel = p
        print("[Debug] WindowManager initialized")
    }
    
    func showNotification(_ notification: CapturedNotification) {
        guard let panel = self.panel else { return }
        
        print("[Debug] showNotification called. ID: \(notification.id)")
        
        // Update current ID
        self.currentNotificationId = notification.id
        
        // 1. Create the SwiftUI Root View for the panel
        // We wrap the island in a container that handles the state/animation internally
        let rootView = DynamicIslandContainer(notification: notification) { [weak self] in
            // Cleanup closure when animation is done
            // Pass the ID to ensure we only hide if this specific notification is the one requesting it
            print("[Debug] Callback: Container requested hide for ID: \(notification.id)")
            self?.hidePanel(for: notification.id)
        }
        
        // 2. Set the content
        // FIX: Always create a fresh NSHostingView. Reusing the old one while swapping rootViews
        // often fails to trigger onAppear if the window was hidden.
        let newHostingView = NSHostingView(rootView: rootView)
        panel.contentView = newHostingView
        self.hostingView = newHostingView
        
        // 3. Position: Top Right of Main Screen
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            // Position 20px from right, near the top (below menu bar)
            let xPos = visibleFrame.maxX - 420 // Width (380) + Padding
            let yPos = visibleFrame.maxY - 120  // Height + Padding
            
            panel.setFrameOrigin(NSPoint(x: xPos, y: yPos))
        }
        
        // 4. Show it without activating app (prevents stealing focus)
        self.isPanelActive = true
        panel.orderFrontRegardless()
    }
    
    private func hidePanel(for id: UUID) {
        // Critical Fix: Only close if the requesting notification is still the active one.
        // This prevents old timers from closing new notifications.
        print("[Debug] hidePanel called for ID: \(id). Current Active: \(currentNotificationId?.uuidString ?? "nil")")
        
        guard currentNotificationId == id else {
            print("[Debug] hidePanel ignored: ID mismatch (New notification already active)")
            return
        }
        
        // We don't actually close the panel, just hide it or let the view collapse.
        // For efficiency, we can orderOut if truly done.
        panel?.orderOut(nil)
        self.isPanelActive = false
        self.currentNotificationId = nil
        print("[Debug] Panel hidden successfully")
    }
}

// MARK: - Dynamic Island Container (Manages its own animation)
struct DynamicIslandContainer: View {
    let notification: CapturedNotification
    var onDismiss: () -> Void
    
    @State private var islandState: IslandState = .idle
    @State private var viewOpacity: Double = 0.0 // Start invisible to prevent "stuck" glitches
    
    enum IslandState {
        case idle
        case expanded
    }
    
    var isExpanded: Bool { islandState == .expanded }
    
    var body: some View {
        // The view itself is transparent, holding the island
        ZStack(alignment: .topTrailing) {
            Color.clear // Transparent background for the window content area
            
            HStack(alignment: .center, spacing: 0) {
                // LEFT: App Icon
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: isExpanded ? 40 : 10, height: isExpanded ? 40 : 10)
                        .opacity(isExpanded ? 1 : 0)
                    
                    Image(systemName: "bell.badge.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                        .foregroundColor(.white)
                        .opacity(isExpanded ? 1 : 0)
                }
                .frame(width: isExpanded ? 50 : 0)
                .clipped()
                
                // CENTER: Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(notification.title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .opacity(isExpanded ? 1 : 0)
                        .scaleEffect(isExpanded ? 1 : 0.8, anchor: .leading)
                    
                    if !notification.body.isEmpty {
                        Text(notification.body)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.white.opacity(0.8))
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
                        .padding(.leading, 10)
                }
            }
            .padding(.horizontal, isExpanded ? 16 : 0)
            .padding(.vertical, isExpanded ? 16 : 0)
            .frame(width: isExpanded ? 380 : 40, height: isExpanded ? 90 : 12)
            .background(
                Color.black // Solid black as requested
                    .shadow(color: .black.opacity(0.3), radius: 15, x: 0, y: 5)
            )
            .clipShape(RoundedRectangle(cornerRadius: isExpanded ? 40 : 20, style: .continuous))
            .padding(.top, 10)
            .padding(.trailing, 10)
            .onTapGesture {
                print("[Debug] User tapped notification")
                dismiss()
            }
        }
        .opacity(viewOpacity) // Apply fade out to whole view
        .id(notification.id) // Critical Fix: Force view recreation to restart animation
        .onAppear {
            print("[Debug] Container onAppear for ID: \(notification.id)")
            // Sequence the animation
            
            // 1. Fade In
            withAnimation(.easeIn(duration: 0.2)) {
                viewOpacity = 1.0
            }
            
            // 2. Expand
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.interactiveSpring(response: 0.6, dampingFraction: 0.7)) {
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
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            islandState = .idle
        }
        
        // 2. Fade Out Animation (Simultaneous)
        // Removing the delay ensures that if it shrinks to a capsule, it's already invisible
        withAnimation(.easeOut(duration: 0.3)) {
            viewOpacity = 0
        }
        
        // 3. Tell the window manager to hide the panel after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            onDismiss()
        }
    }
}

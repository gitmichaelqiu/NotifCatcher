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
                        Text("Minimize this window. The Island will appear at the top center of your screen.")
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
            // Trigger the Dynamic Island
            windowManager.showNotification(newNotif)
        }
    }
}

// MARK: - Floating Window Manager
class FloatingNotificationManager: ObservableObject {
    private var panel: NSPanel?
    private var currentNotificationId: UUID?
    
    // Config: Center the window at the top of the screen
    // We make the window wide enough to hold the expanded animation, but clear background.
    private let windowWidth: CGFloat = 600
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
        // Level must be higher than the Menu Bar (Main Menu + 1)
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.ignoresMouseEvents = false // Allow interaction
        
        self.panel = p
    }
    
    func showNotification(_ notification: CapturedNotification) {
        guard let panel = self.panel else { return }
        
        self.currentNotificationId = notification.id
        
        // 1. Position Window: Top Center
        if let screen = NSScreen.main {
            let screenFrame = screen.frame
            // X: Center of screen - half of window width
            let xPos = screenFrame.midX - (windowWidth / 2)
            // Y: Top of screen - window height (macOS coordinates start at bottom)
            // We adjust slightly down so the "island" sits visually within the bezel/notch area
            let yPos = screenFrame.maxY - windowHeight
            
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
        // We don't actually close the window immediately, we let the SwiftUI view animate out.
        // But for safety, we can clear content after a delay if needed.
        // For this demo, we just leave the window ready for the next one.
        // If we wanted to "hide" it completely:
        // panel?.orderOut(nil)
    }
}

// MARK: - Dynamic Island View
struct DynamicIslandContainer: View {
    let notification: CapturedNotification
    var onDismiss: () -> Void
    
    // Animation States
    @State private var islandState: IslandState = .hidden
    
    enum IslandState {
        case hidden     // Invisible/Tiny
        case idle       // The "Notch" pill shape
        case expanded   // The full notification
    }
    
    // Physics Configuration (Apple-like Spring)
    private let springAnim = Animation.interpolatingSpring(mass: 1.0, stiffness: 220, damping: 22, initialVelocity: 0)
    
    // Dimensions
    // Idle: Matches standard MacBook Notch (~150x32)
    private let idleWidth: CGFloat = 160
    private let idleHeight: CGFloat = 32
    
    // Expanded: Large banner
    private let expandedWidth: CGFloat = 420
    private let expandedHeight: CGFloat = 92
    
    var isExpanded: Bool { islandState == .expanded }
    var isHidden: Bool { islandState == .hidden }
    
    var body: some View {
        VStack {
            // The Island
            ZStack {
                // Background Layer (Black Glass)
                RoundedRectangle(cornerRadius: isExpanded ? 24 : 16, style: .continuous)
                    .fill(.black)
                    .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
                
                // Border (Subtle shine)
                RoundedRectangle(cornerRadius: isExpanded ? 24 : 16, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                
                // CONTENT LAYER
                HStack(spacing: 12) {
                    // LEFT: Icon
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [.indigo, .purple], startPoint: .top, endPoint: .bottom))
                            .frame(width: isExpanded ? 40 : 0, height: isExpanded ? 40 : 0)
                            .opacity(isExpanded ? 1 : 0)
                        
                        Image(systemName: "bell.fill")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 18, height: 18)
                            .foregroundColor(.white)
                            .opacity(isExpanded ? 1 : 0)
                    }
                    
                    // CENTER: Text Info
                    if isExpanded {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notification.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            
                            if !notification.body.isEmpty {
                                Text(notification.body)
                                    .font(.system(size: 13))
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    // RIGHT: Time/Visualizer
                    if isExpanded {
                        Text("Now")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                
                // NOTCH MASK (Visual trickery)
                // This simulates the hardware camera cutout if needed,
                // but for a purely software solution, just the black pill is usually enough.
            }
            // Dynamic Sizing
            .frame(width: isExpanded ? expandedWidth : (isHidden ? 0 : idleWidth),
                   height: isExpanded ? expandedHeight : (isHidden ? 0 : idleHeight))
            .onTapGesture {
                dismissSequence()
            }
            .padding(.top, 0) // Pin to very top
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .id(notification.id)
        .onAppear {
            runPresentationSequence()
        }
    }
    
    private func runPresentationSequence() {
        // 1. Init state (already hidden)
        
        // 2. Expand to "Notch" (Idle state) immediately
        withAnimation(.easeOut(duration: 0.2)) {
            islandState = .idle
        }
        
        // 3. Expand to Notification (Bounce)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(springAnim) {
                islandState = .expanded
            }
        }
        
        // 4. Auto Dismiss after 4 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            dismissSequence()
        }
    }
    
    private func dismissSequence() {
        // 1. Shrink back to Notch
        withAnimation(springAnim) {
            islandState = .idle
        }
        
        // 2. Disappear completely
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.easeIn(duration: 0.2)) {
                islandState = .hidden
            }
            
            // 3. Cleanup
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                onDismiss()
            }
        }
    }
}

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
    }
}

// MARK: - Floating Window Manager
class FloatingNotificationManager: ObservableObject {
    private var panel: NSPanel?
    private var currentNotificationId: UUID?
    
    // Config: Position logic for Top Right
    private let windowWidth: CGFloat = 400
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
        
        // Start hidden completely
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
            let rightPadding: CGFloat = 10
            let xPos = visibleFrame.maxX - windowWidth - rightPadding
            let yPos = visibleFrame.maxY - windowHeight
            
            panel.setFrame(NSRect(x: xPos, y: yPos, width: windowWidth, height: windowHeight), display: true)
        }
        
        let rootView = DynamicIslandContainer(notification: notification) { [weak self] in
            self?.hidePanel()
        }
        
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        
        panel.contentView = hostingView
        
        // ACTIVATE: Make visible and clickable
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
    }
    
    private func hidePanel() {
        print("[WindowManager] Hiding panel and disabling clicks")
        // DEACTIVATE: Completely remove window from screen
        // This ensures it cannot intercept clicks
        panel?.orderOut(nil)
        panel?.alphaValue = 0
        panel?.ignoresMouseEvents = true
    }
}

// MARK: - Dynamic Island View
struct DynamicIslandContainer: View {
    let notification: CapturedNotification
    var onDismiss: () -> Void
    
    @State private var isExpanded: Bool = false
    @State private var isVisible: Bool = false
    
    private let springAnim = Animation.interpolatingSpring(mass: 0.5, stiffness: 200, damping: 18, initialVelocity: 0.5)
    
    private let startWidth: CGFloat = 20
    private let startHeight: CGFloat = 0
    private let expandedWidth: CGFloat = 360
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
                    // LEFT: Icon (Profile Pic Priority -> App Icon -> Fallback)
                    ZStack {
                        if let profile = notification.profileImage {
                             // Case 1: Profile Photo (Circle)
                            Image(nsImage: profile)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: isExpanded ? 38 : 0, height: isExpanded ? 38 : 0)
                                .clipShape(Circle())
                                .opacity(isExpanded ? 1 : 0)
                        } else if let appIcon = notification.icon {
                            // Case 2: App Icon (Rounded Square)
                            Image(nsImage: appIcon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: isExpanded ? 38 : 0, height: isExpanded ? 38 : 0)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .opacity(isExpanded ? 1 : 0)
                        } else {
                            // Case 3: Fallback
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
                dismissSequence()
            }
            .padding(.top, 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.trailing, 0)
        .id(notification.id)
        .onAppear {
            runPresentationSequence()
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

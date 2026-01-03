import SwiftUI

struct ContentView: View {
    @StateObject var monitor = NotificationMonitor()
    
    // Animation State
    @State private var activeNotification: CapturedNotification?
    @State private var islandState: IslandState = .idle
    
    enum IslandState {
        case idle       // Hidden/Small
        case expanded   // Full Notification
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            // MARK: - Main App Control Panel
            // This stays in the background
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
                        Text("Waiting for notifications...")
                            .font(.caption)
                            .padding(.top)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            
            // MARK: - The Dynamic Island Layer
            // Floating on top of everything
            if let notification = activeNotification {
                DynamicIslandView(notification: notification, state: islandState)
                    .padding(.top, 20) // Distance from top of screen/window
                    .onTapGesture {
                        // Dismiss on tap
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                            islandState = .idle
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            activeNotification = nil
                        }
                    }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        // Listen for new data from the Monitor Logic
        .onChange(of: monitor.latestNotification) { newValue in
            guard let newNotif = newValue else { return }
            handleNewNotification(newNotif)
        }
    }
    
    // Logic to sequence the "Pop and Expand" animation
    private func handleNewNotification(_ notification: CapturedNotification) {
        // 1. Reset if needed
        if islandState == .expanded {
            islandState = .idle
        }
        
        // 2. Set Data
        activeNotification = notification
        
        // 3. Animate Expansion
        // Small delay to allow the view to render in "idle" state first if needed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.interactiveSpring(response: 0.6, dampingFraction: 0.7, blendDuration: 0.25)) {
                islandState = .expanded
            }
        }
        
        // 4. Auto Dismiss Timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            // Only dismiss if it's still the same notification
            if activeNotification == notification {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                    islandState = .idle
                }
                // Actually remove the view after animation finishes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if activeNotification == notification {
                        activeNotification = nil
                    }
                }
            }
        }
    }
}

// MARK: - Dynamic Island Component
struct DynamicIslandView: View {
    let notification: CapturedNotification
    let state: ContentView.IslandState
    
    // Animation constants
    var isExpanded: Bool { state == .expanded }
    
    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            
            // LEFT: App Icon
            ZStack {
                Circle()
                    .fill(Color.blue.gradient)
                    .frame(width: isExpanded ? 40 : 10, height: isExpanded ? 40 : 10)
                    .opacity(isExpanded ? 1 : 0) // Fade in
                
                Image(systemName: "bell.badge.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
                    .foregroundColor(.white)
                    .opacity(isExpanded ? 1 : 0)
            }
            .frame(width: isExpanded ? 50 : 0) // Collapse width when idle
            .clipped()
            
            // CENTER: Text Content
            VStack(alignment: .leading, spacing: 4) {
                Text(notification.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .blur(radius: isExpanded ? 0 : 10) // Blur effect during expansion
                    .opacity(isExpanded ? 1 : 0)
                    .scaleEffect(isExpanded ? 1 : 0.8, anchor: .leading)
                
                if !notification.body.isEmpty {
                    Text(notification.body)
                        .font(.system(size: 13, weight: .regular, design: .default))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(2)
                        .blur(radius: isExpanded ? 0 : 5)
                        .opacity(isExpanded ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: isExpanded ? nil : 0) // Collapse height
            .opacity(isExpanded ? 1 : 0)
            
            // RIGHT: Time/Action (Optional)
            if isExpanded {
                Text("Now")
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .padding(.leading, 10)
                    .transition(.opacity.animation(.easeInOut.delay(0.2)))
            }
        }
        // Island Dimensions
        .padding(.horizontal, isExpanded ? 16 : 0)
        .padding(.vertical, isExpanded ? 16 : 0)
        .frame(width: isExpanded ? 380 : 40, height: isExpanded ? 90 : 12)
        .background(
            Color.black
                .opacity(0.95)
                .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
        )
        // The signature "Squircle" shape
        .clipShape(RoundedRectangle(cornerRadius: isExpanded ? 40 : 20, style: .continuous))
        // The smooth spring animation is driven by the state change passed from parent
    }
}

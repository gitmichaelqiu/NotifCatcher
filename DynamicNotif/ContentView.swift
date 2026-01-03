import SwiftUI

struct ContentView: View {
    @StateObject var monitor = NotificationMonitor()
    @State private var showBanner = false
    
    var body: some View {
        VStack(spacing: 20) {
            // Status Indicator Area
            VStack {
                Image(systemName: monitor.permissionGranted ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 40))
                    .foregroundColor(monitor.permissionGranted ? .green : .red)
                
                Text(monitor.permissionGranted ? "Access Granted" : "Permission Needed")
                    .font(.headline)
                
                if !monitor.permissionGranted {
                    Text("Please grant Accessibility permission in System Settings, then restart the app.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding()
                } else if !monitor.isListening {
                    Button("Start Monitoring") {
                        monitor.startMonitoring()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("Listening for system notifications...")
                        .foregroundColor(.secondary)
                    Text("Send a message or run terminal command:\n osascript -e 'display notification \"Hello\"'")
                        .font(.caption)
                        .padding(.top)
                }
            }
            .padding()
            .frame(width: 300, height: 200)
        }
        // This overlay is your "Reshaped" Notification
        .overlay(alignment: .top) {
            if showBanner, let notif = monitor.latestNotification {
                CustomNotificationBanner(notification: notif)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .offset(y: 50) // Push it down a bit
                    .onTapGesture {
                        withAnimation { showBanner = false }
                    }
            }
        }
        .onChange(of: monitor.latestNotification) { newValue in
            if newValue != nil {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    showBanner = true
                }
                
                // Auto-hide after 4 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    withAnimation {
                        // Only hide if it's still the same notification
                        if monitor.latestNotification == newValue {
                            showBanner = false
                        }
                    }
                }
            }
        }
    }
}

// Your Custom "Reshaped" Design
struct CustomNotificationBanner: View {
    let notification: CapturedNotification
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 40, height: 40)
                
                Image(systemName: "bell.badge.fill")
                    .foregroundColor(.white)
            }
            
            // Text
            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                
                Text(notification.body)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(2)
            }
            
            Spacer()
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.6))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
        .frame(width: 350)
    }
}

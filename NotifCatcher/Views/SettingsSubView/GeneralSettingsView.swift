import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var monitor: NotificationMonitor
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                
                SettingsSection("Status") {
                    SettingsRow("Monitoring Service", helperText: "Controls whether the app is actively listening for notifications.") {
                        Toggle("", isOn: Binding(
                            get: { monitor.isListening },
                            set: { val in if val { monitor.startMonitoring() } }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(monitor.isListening) // Only allow start
                    }
                    
                    Divider()
                    
                    SettingsRow("Accessibility Permission") {
                        HStack {
                            if monitor.permissionGranted {
                                Label("Granted", systemImage: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            } else {
                                Label("Missing", systemImage: "xmark.circle.fill")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
                
                SettingsSection("Behavior") {
                    SettingsRow("Auto-Dismiss Time", helperText: "How long the island stays visible.") {
                        Text("5 seconds")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

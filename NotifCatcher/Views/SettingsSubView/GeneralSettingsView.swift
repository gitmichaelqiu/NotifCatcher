import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var monitor: NotificationMonitor
    
    var body: some View {
        SettingsSection("Status") {
            SettingsRow("Monitoring Service", helperText: "Controls whether the app is actively listening for notifications.") {
                Toggle("", isOn: Binding(get: { monitor.isListening }, set: { val in if val { monitor.startMonitoring() } }))
                    .toggleStyle(.switch).labelsHidden().disabled(monitor.isListening)
            }
            Divider()
            SettingsRow("Accessibility Permission") {
                HStack {
                    if monitor.permissionGranted { Label("Granted", systemImage: "checkmark.circle.fill").foregroundColor(.green) }
                    else { Label("Missing", systemImage: "xmark.circle.fill").foregroundColor(.red) }
                }
            }
        }
    }
}

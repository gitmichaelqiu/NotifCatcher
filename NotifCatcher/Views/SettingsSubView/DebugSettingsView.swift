import SwiftUI

struct DebugSettingsView: View {
    @ObservedObject var monitor: NotificationMonitor
    @ObservedObject var windowManager: FloatingNotificationManager
    @State private var logText: String = "Waiting for notifications..."
    @State private var count: Int = 0
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                
                SettingsSection("Test Tools") {
                    SettingsRow("Trigger Test Notification", helperText: "Simulate incoming system notifications to test the Island animation and capture logic.") {
                        HStack(spacing: 12) {
                            Button("Single") { sendTest(delay: 0) }
                            Button("Burst (3x)") {
                                sendTest(delay: 0.1)
                                sendTest(delay: 1.2)
                                sendTest(delay: 2.5)
                            }
                            Button("Send OTP") {
                                sendTest(delay: 0, body: "Your login code is \(Int.random(in: 1000...9999)).")
                            }
                        }
                    }
                }
                
                SettingsSection("Live Log") {
                    VStack(spacing: 0) {
                        ScrollView {
                            Text(logText)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .frame(height: 250)
                        .background(Color.black)
                        .foregroundColor(.green)
                    }
                    .cornerRadius(8)
                    .padding(6)
                }
                .onReceive(monitor.notificationSubject) { n in
                    let ts = Date().formatted(.dateTime.hour().minute().second())
                    logText = "[\(ts)] \(n.title) | OTP: \(n.otpCode ?? "No")\n" + logText
                }
                
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
    
    func sendTest(delay: Double, body: String? = nil) {
        count += 1
        let id = count
        let txt = body ?? "Debug message #\(id)"
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            let script = "display notification \"\(txt)\" with title \"Test Notification\""
            let proc = Process()
            proc.launchPath = "/usr/bin/osascript"
            proc.arguments = ["-e", script]
            try? proc.run()
        }
    }
}

import SwiftUI

struct IslandSettingsView: View {
    @ObservedObject var settings: IslandSettingsManager
    @ObservedObject var windowManager: FloatingNotificationManager
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                
                SettingsSection("Preview") {
                    SettingsRow("Show Preview") {
                        Button("Test Notification") {
                            sendPreviewNotification()
                        }
                    }
                }
                
                SettingsSection("Dimensions") {
                    SliderSectionRow(
                        title: "Island Width",
                        value: $settings.width,
                        range: 300...600,
                        step: 10,
                        specifier: "%.0f px"
                    )
                    
                    Divider()
                    
                    SliderSectionRow(
                        title: "Right Edge Gap",
                        value: $settings.rightPadding,
                        range: -100...50,
                        step: 1,
                        specifier: "%.0f px"
                    )
                }
                
                SettingsSection("Timing") {
                    SliderSectionRow(
                        title: "Display Duration",
                        value: $settings.displayDuration,
                        range: 2.0...15.0,
                        step: 0.5,
                        specifier: "%.1f s"
                    )
                }
                
                SettingsSection("Actions") {
                    SettingsRow("Reset") {
                        Button("Restore Defaults") {
                            withAnimation {
                                settings.resetToDefaults()
                            }
                        }
                    }
                }
                
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
    
    private func sendPreviewNotification() {
        let dummy = CapturedNotification(
            title: "Preview Message",
            body: "Adjust settings to see changes live.",
            appName: "NotifCatcher",
            icon: NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil),
            profileImage: nil,
            otpCode: nil,
            dismissAction: nil
        )
        windowManager.showNotification(dummy)
    }
    
    // Custom Full-Width Slider Row (Matched to DesktopRenamer)
    struct SliderSectionRow: View {
        let title: LocalizedStringKey
        @Binding var value: Double
        let range: ClosedRange<Double>
        let step: Double
        let specifier: String
        
        var body: some View {
            VStack(spacing: 6) {
                // Top Row: Title and Value
                HStack {
                    Text(title)
                    Spacer()
                    Text("\(value, specifier: specifier)")
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                
                // Bottom Row: Full Width Slider
                Slider(value: $value, in: range, step: step)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
        }
    }
}

import SwiftUI

struct IslandSettingsView: View {
    @ObservedObject var settings: IslandSettingsManager
    @ObservedObject var windowManager: FloatingNotificationManager
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                
                SettingsSection("Preview") {
                    SettingsRow("Show Preview") {
                        Button("Trigger Island") {
                            windowManager.triggerPreview()
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
                    // Live Preview Trigger
                    .onChange(of: settings.width) { _ in windowManager.triggerPreview() }
                    
                    Divider()
                    
                    SliderSectionRow(
                        title: "Right Edge Gap",
                        value: $settings.rightPadding,
                        range: -100...50,
                        step: 1,
                        specifier: "%.0f px"
                    )
                    // Live Preview Trigger
                    .onChange(of: settings.rightPadding) { _ in windowManager.triggerPreview() }
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
                                windowManager.triggerPreview()
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

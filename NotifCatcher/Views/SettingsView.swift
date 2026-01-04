import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, island, debug, about
    var id: String { self.rawValue }
    
    var localizedName: LocalizedStringKey {
        switch self {
        case .general: return "General"
        case .island: return "Island"
        case .debug: return "Debug"
        case .about: return "About"
        }
    }
    
    var iconName: String {
        switch self {
        case .general: return "gearshape"
        case .island: return "slider.horizontal.3"
        case .debug: return "ladybug"
        case .about: return "info.circle"
        }
    }
}

let sidebarWidth: CGFloat = 180
let defaultSettingsWindowWidth = 750
let defaultSettingsWindowHeight = 550
let sidebarRowHeight: CGFloat = 32
let sidebarFontSize: CGFloat = 16
let titleHeaderHeight: CGFloat = 48

struct SettingsView: View {
    @ObservedObject var monitor: NotificationMonitor
    @ObservedObject var windowManager: FloatingNotificationManager
    @ObservedObject var settings: IslandSettingsManager
    @State private var selectedTab: SettingsTab? = .general
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Section {
                    ForEach(SettingsTab.allCases) { tab in
                        NavigationLink(value: tab) {
                            Label {
                                Text(tab.localizedName).font(.system(size: sidebarFontSize, weight: .medium)).padding(.leading, 2)
                            } icon: { Image(systemName: tab.iconName).resizable().scaledToFit().frame(height: sidebarRowHeight-15) }
                        }
                        .frame(height: sidebarRowHeight)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 45)
                        Text("Notif").font(.system(size: 28, weight: .heavy)).foregroundStyle(.primary)
                        Text("Catcher").font(.system(size: 28, weight: .heavy)).foregroundStyle(.primary).padding(.bottom, 20)
                    }
                }
                .collapsible(false)
            }
            .scrollDisabled(true)
            .removeSidebarToggle()
            .navigationSplitViewColumnWidth(min: sidebarWidth, ideal: sidebarWidth, max: sidebarWidth)
            .edgesIgnoringSafeArea(.top)
        } detail: {
            ZStack(alignment: .top) {
                if let tab = selectedTab {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            switch tab {
                            case .general: GeneralSettingsView(monitor: monitor)
                            case .island: IslandSettingsView(settings: settings, windowManager: windowManager)
                            case .debug: DebugSettingsView(monitor: monitor, windowManager: windowManager)
                            case .about: AboutView()
                            }
                        }
                        .padding(.top, titleHeaderHeight + 20).padding()
                    }
                    VStack(spacing: 0) {
                        HStack { Text(tab.localizedName).font(.system(size: 20, weight: .semibold)).padding(.leading, 20); Spacer() }
                            .frame(height: titleHeaderHeight).background(.bar)
                        Divider()
                    }
                }
            }
            .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
            .edgesIgnoringSafeArea(.top)
        }
        .frame(width: CGFloat(defaultSettingsWindowWidth), height: CGFloat(defaultSettingsWindowHeight))
    }
}

class SettingsHostingController: NSHostingController<SettingsView> {
    init(monitor: NotificationMonitor, windowManager: FloatingNotificationManager, settings: IslandSettingsManager) {
        super.init(rootView: SettingsView(monitor: monitor, windowManager: windowManager, settings: settings))
    }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        self.preferredContentSize = NSSize(width: defaultSettingsWindowWidth, height: defaultSettingsWindowHeight)
    }
}

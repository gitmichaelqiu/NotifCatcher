import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, debug, about
    
    var id: String { self.rawValue }
    
    var localizedName: LocalizedStringKey {
        switch self {
        case .general: return "General"
        case .debug: return "Debug"
        case .about: return "About"
        }
    }
    
    var iconName: String {
        switch self {
        case .general: return "gearshape"
        case .debug: return "ladybug"
        case .about: return "info.circle"
        }
    }
}

// Layout Constants (Matched to DesktopRenamer)
let sidebarWidth: CGFloat = 180
let defaultSettingsWindowWidth = 750
let defaultSettingsWindowHeight = 550
let sidebarRowHeight: CGFloat = 32
let sidebarFontSize: CGFloat = 16

// Tighter Header Height
let titleHeaderHeight: CGFloat = 48

struct SettingsView: View {
    @ObservedObject var monitor: NotificationMonitor
    @ObservedObject var windowManager: FloatingNotificationManager
    
    @State private var selectedTab: SettingsTab? = .general
    
    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .navigationTitle("")
        .toolbar(.hidden, for: .windowToolbar)
        .edgesIgnoringSafeArea(.top)
        .frame(width: CGFloat(defaultSettingsWindowWidth), height: CGFloat(defaultSettingsWindowHeight))
    }
    
    @ViewBuilder
    private var sidebar: some View {
        if #available(macOS 14.0, *) {
            List(selection: $selectedTab) {
                Section {
                    ForEach(SettingsTab.allCases) { tab in
                        sidebarItem(for: tab)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 45)
                        
                        Text("Notif")
                            .font(.system(size: 28, weight: .heavy))
                            .foregroundStyle(.primary)
                        Text("Catcher")
                            .font(.system(size: 28, weight: .heavy))
                            .foregroundStyle(.primary)
                            .padding(.bottom, 20)
                    }
                }
                .collapsible(false)
            }
            .scrollDisabled(true)
            .removeSidebarToggle()
            .navigationSplitViewColumnWidth(min: sidebarWidth, ideal: sidebarWidth, max: sidebarWidth)
            .edgesIgnoringSafeArea(.top)
        } else {
            List(selection: $selectedTab) {
                Section {
                    ForEach(SettingsTab.allCases) { tab in
                        sidebarItem(for: tab)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 45)
                        
                        Text("Notif")
                            .font(.system(size: 28, weight: .heavy))
                            .foregroundStyle(.primary)
                        Text("Catcher")
                            .font(.system(size: 28, weight: .heavy))
                            .foregroundStyle(.primary)
                            .padding(.bottom, 20)
                    }
                }
                .collapsible(false)
            }
            .scrollDisabled(true)
            .navigationSplitViewColumnWidth(min: sidebarWidth, ideal: sidebarWidth, max: sidebarWidth)
            .listStyle(.sidebar)
            .edgesIgnoringSafeArea(.top)
        }
    }
    
    @ViewBuilder
    private var detailView: some View {
        ZStack(alignment: .top) {
            
            // 1. CONTENT LAYER
            ZStack(alignment: .top) {
                if let tab = selectedTab {
                    switch tab {
                    case .general:
                        GeneralSettingsView(monitor: monitor)
                    case .debug:
                        DebugSettingsView(monitor: monitor, windowManager: windowManager)
                    case .about:
                        AboutView()
                    }
                } else {
                    Text("Select a category")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Match the header height exactly
            .padding(.top, titleHeaderHeight)
            
            // 2. HEADER LAYER (Blurry Title Bar)
            if let tab = selectedTab {
                VStack(spacing: 0) {
                    HStack {
                        Text(tab.localizedName)
                            .font(.system(size: 20, weight: .semibold))
                            .padding(.leading, 20)
                        Spacer()
                    }
                    .frame(height: titleHeaderHeight) // 48pt
                    .background(.bar)
                    
                    Divider()
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .edgesIgnoringSafeArea(.top)
    }
    
    @ViewBuilder
    private func sidebarItem(for tab: SettingsTab) -> some View {
        NavigationLink(value: tab) {
            Label {
                Text(tab.localizedName)
                    .font(.system(size: sidebarFontSize, weight: .medium))
                    .padding(.leading, 2)
            } icon: {
                Image(systemName: tab.iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(height: sidebarRowHeight-15)
            }
        }
        .frame(height: sidebarRowHeight)
    }
}

class SettingsHostingController: NSHostingController<SettingsView> {
    private let monitor: NotificationMonitor
    private let windowManager: FloatingNotificationManager
    
    init(monitor: NotificationMonitor, windowManager: FloatingNotificationManager) {
        self.monitor = monitor
        self.windowManager = windowManager
        super.init(rootView: SettingsView(monitor: monitor, windowManager: windowManager))
    }
    
    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.preferredContentSize = NSSize(width: defaultSettingsWindowWidth, height: defaultSettingsWindowHeight)
    }
}

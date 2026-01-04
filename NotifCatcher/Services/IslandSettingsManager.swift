import Foundation
import Combine

class IslandSettingsManager: ObservableObject {
    private let kIslandWidth = "kIslandWidth"
    private let kRightPadding = "kRightPadding"
    private let kDisplayDuration = "kDisplayDuration"
    
    @Published var width: Double { didSet { UserDefaults.standard.set(width, forKey: kIslandWidth) } }
    @Published var rightPadding: Double { didSet { UserDefaults.standard.set(rightPadding, forKey: kRightPadding) } }
    @Published var displayDuration: Double { didSet { UserDefaults.standard.set(displayDuration, forKey: kDisplayDuration) } }
    
    init() {
        UserDefaults.standard.register(defaults: [
            kIslandWidth: 380.0,
            kRightPadding: -35.0,
            kDisplayDuration: 5.0
        ])
        
        self.width = UserDefaults.standard.double(forKey: kIslandWidth)
        self.rightPadding = UserDefaults.standard.double(forKey: kRightPadding)
        self.displayDuration = UserDefaults.standard.double(forKey: kDisplayDuration)
        
        // Sanity checks for first launch or corrupted defaults
        if self.width == 0 { self.width = 380.0 }
        if self.displayDuration == 0 { self.displayDuration = 5.0 }
    }
    
    func resetToDefaults() {
        self.width = 380.0
        self.rightPadding = -35.0
        self.displayDuration = 5.0
    }
}

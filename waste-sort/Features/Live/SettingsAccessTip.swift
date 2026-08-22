import Foundation
import TipKit

/// Reveals the otherwise-invisible gesture that opens developer settings
/// (long-press the stats tab). Disappears permanently once used.
struct SettingsAccessTip: Tip {
    static let performedKey = Events.settingsOpenedViaLongPress

    enum Events {
        static let settingsOpenedViaLongPress = Tips.Event(id: "settings-opened-via-long-press")
    }

    var title: Text {
        Text("Everything is tunable")
    }

    var message: Text? {
        Text("Long-press here to open developer settings — model weights, thresholds, cameras, and zone calibration.")
    }

    var image: Image? {
        Image(systemName: "slider.horizontal.3")
    }

    var options: [any TipOption] {
        [MaxDisplayCount(3)]
    }
}

import Foundation

/// The seven onboarding screens, in order. Copy is verbatim from the design.
enum OnboardingPage: Int, CaseIterable, Identifiable, Sendable {
    case welcome
    case sortWaste
    case trackWaste
    case meetStation
    case setUpIPad
    case setUpCamera
    case allSet

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome to Sortla!"
        case .sortWaste: return "We help you sort waste"
        case .trackWaste: return "We help track waste"
        case .meetStation: return "Meet the sorting station"
        case .setUpIPad: return "Set up the iPad"
        case .setUpCamera: return "Set up the Camera"
        case .allSet: return "You’re all set"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:
            return "A smarter way to sort, track, and understand your waste, "
                + "making waste management simple and accessible."
        case .sortWaste: return "You bring the waste, we’ll find its bin."
        case .trackWaste: return "You sort the waste, we’ll track it."
        case .meetStation: return "A simple minimal system, designed to make sorting effortless."
        case .setUpIPad: return "Place it above the bins, at a comfortable viewing height."
        case .setUpCamera: return "Place it on top of the iPad, facing down & connect it."
        case .allSet: return "Everything is set up and ready to sort."
        }
    }

    var primaryTitle: String {
        switch self {
        case .welcome: return "Let’s Start!"
        case .sortWaste, .trackWaste: return "Continue"
        case .meetStation: return "Set up"
        case .setUpIPad, .setUpCamera: return "Next"
        case .allSet: return "Start Sorting"
        }
    }

    /// The underlined link under the call to action, when the page has one.
    var secondaryTitle: String? {
        switch self {
        case .welcome: return "Learn more about our Privacy & Policy"
        case .meetStation: return "Already set up"
        default: return nil
        }
    }

    /// Only the welcome screen hides the Sortla mark and the Skip link.
    var showsChrome: Bool { self != .welcome }

    /// Height of the artwork band, in design points.
    var mediaHeight: CGFloat {
        switch self {
        case .welcome: return 1024
        case .sortWaste, .allSet: return 495
        case .trackWaste: return 562
        case .meetStation, .setUpIPad, .setUpCamera: return 469
        }
    }

    /// The page reached by the primary action, or `nil` when the primary action finishes the flow.
    var next: OnboardingPage? {
        self == .allSet ? nil : OnboardingPage(rawValue: rawValue + 1)
    }
}

/// Which way the flow is travelling, so an arriving page enters from the side the user came from.
enum OnboardingDirection: Sendable {
    case forward
    case backward

    /// Multiplier for the horizontal offset an arriving page enters with.
    var sign: CGFloat { self == .forward ? 1 : -1 }
}

/// Page position plus the trail taken to reach it.
///
/// The trail matters because the flow is not a straight line: "Already set up" jumps from the
/// station page over both mounting steps, and going back from there has to return to the station
/// rather than walk back through the steps that were never shown.
struct OnboardingNavigator: Equatable {
    private(set) var page: OnboardingPage
    private(set) var direction: OnboardingDirection = .forward
    private var history: [OnboardingPage] = []

    init(page: OnboardingPage = .welcome) {
        self.page = page
    }

    var canGoBack: Bool { !history.isEmpty }

    mutating func go(to next: OnboardingPage) {
        history.append(page)
        direction = .forward
        page = next
    }

    mutating func goBack() {
        guard let previous = history.popLast() else { return }
        direction = .backward
        page = previous
    }
}

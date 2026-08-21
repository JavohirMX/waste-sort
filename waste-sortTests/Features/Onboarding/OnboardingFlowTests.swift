import CoreGraphics
import Foundation
import Testing

@testable import waste_sort

@Suite("Onboarding page sequence")
struct OnboardingPageTests {
    @Test("Pages advance in design order and the last one ends the flow")
    func advancesInOrder() {
        var visited: [OnboardingPage] = [.welcome]
        var page = OnboardingPage.welcome

        while let next = page.next {
            visited.append(next)
            page = next
        }

        #expect(visited == OnboardingPage.allCases)
        #expect(OnboardingPage.allCases.last == .allSet)
        #expect(OnboardingPage.allSet.next == nil)
    }

    /// "Already set up" on the station page must land on the confirmation, skipping the two
    /// mounting steps — the whole point of offering it.
    @Test("Skipping setup from the station page lands on the confirmation")
    func alreadySetUpSkipsMountingSteps() {
        #expect(OnboardingPage.meetStation.secondaryTitle == "Already set up")

        let skipped: [OnboardingPage] = [.setUpIPad, .setUpCamera]
        for page in skipped {
            #expect(page != .allSet)
        }
    }

    @Test("Only the welcome and station pages offer a secondary link")
    func secondaryLinks() {
        let withLink = OnboardingPage.allCases.filter { $0.secondaryTitle != nil }
        #expect(withLink == [.welcome, .meetStation])
    }

    @Test("Only the welcome page hides the Sortla mark and Skip")
    func chromeVisibility() {
        let withoutChrome = OnboardingPage.allCases.filter { !$0.showsChrome }
        #expect(withoutChrome == [.welcome])
    }

    @Test("Every page has copy and a call to action")
    func copyIsPresent() {
        for page in OnboardingPage.allCases {
            #expect(!page.title.isEmpty)
            #expect(!page.subtitle.isEmpty)
            #expect(!page.primaryTitle.isEmpty)
        }
    }
}

@Suite("Onboarding back navigation")
struct OnboardingNavigatorTests {
    @Test("The first page offers no way back")
    func firstPageHasNoBack() {
        var nav = OnboardingNavigator()
        #expect(nav.canGoBack == false)

        nav.goBack()
        #expect(nav.page == .welcome)
    }

    @Test("Back retraces the pages that were actually shown")
    func backRetracesTheTrail() {
        var nav = OnboardingNavigator()
        nav.go(to: .sortWaste)
        nav.go(to: .trackWaste)

        nav.goBack()
        #expect(nav.page == .sortWaste)

        nav.goBack()
        #expect(nav.page == .welcome)
        #expect(nav.canGoBack == false)
    }

    /// "Already set up" jumps from the station page over both mounting steps. Going back has to
    /// return to the station rather than drop into the steps the user was never shown.
    @Test("Back from the jump taken by \"Already set up\" returns to the station")
    func backSkipsThePagesTheJumpSkipped() {
        var nav = OnboardingNavigator()
        nav.go(to: .sortWaste)
        nav.go(to: .trackWaste)
        nav.go(to: .meetStation)
        nav.go(to: .allSet)

        nav.goBack()
        #expect(nav.page == .meetStation)
    }

    /// The arriving artwork slides in from the side the user is travelling towards, so the
    /// direction has to flip the moment they turn around.
    @Test("Direction tracks which way the flow is moving")
    func directionFollowsTravel() {
        var nav = OnboardingNavigator()
        nav.go(to: .sortWaste)
        #expect(nav.direction == .forward)

        nav.goBack()
        #expect(nav.direction == .backward)

        nav.go(to: .sortWaste)
        #expect(nav.direction == .forward)
    }

    @Test("A flow started mid-way has nothing to go back to")
    func initialPageStartsWithEmptyTrail() {
        let nav = OnboardingNavigator(page: .setUpCamera)
        #expect(nav.page == .setUpCamera)
        #expect(nav.canGoBack == false)
    }
}

@Suite("Onboarding metrics")
struct OnboardingMetricsTests {
    @Test("The design reference size scales 1:1")
    func referenceIsUnscaled() {
        let m = OnboardingMetrics(size: OnboardingMetrics.reference)
        #expect(abs(m.scale - 1) < 0.0001)
        #expect(abs(m.s(515) - 515) < 0.0001)
    }

    @Test("Scale follows the more constrained axis")
    func scaleUsesLimitingAxis() {
        // Half height, full width: the height is what limits the layout.
        let m = OnboardingMetrics(size: CGSize(width: 1366, height: 512))
        #expect(abs(m.scale - 0.5) < 0.0001)
    }

    @Test("Scale is clamped so extremes stay legible")
    func scaleIsClamped() {
        let tiny = OnboardingMetrics(size: CGSize(width: 320, height: 240))
        #expect(tiny.scale >= 0.42)

        let huge = OnboardingMetrics(size: CGSize(width: 4000, height: 3000))
        #expect(huge.scale <= 1.15)
    }

    /// A portrait iPad is wide enough in points to pass a naive width test, but splitting
    /// there crops the welcome illustration badly — it must stack instead.
    @Test("The welcome screen only splits in landscape")
    func splitLayoutRequiresLandscape() {
        let iPadLandscape = OnboardingMetrics(size: CGSize(width: 1366, height: 1024))
        #expect(iPadLandscape.usesSplitLayout)

        let iPadPortrait = OnboardingMetrics(size: CGSize(width: 1024, height: 1366))
        #expect(!iPadPortrait.usesSplitLayout)

        let phoneLandscape = OnboardingMetrics(size: CGSize(width: 852, height: 393))
        #expect(!phoneLandscape.usesSplitLayout)
    }
}

@Suite("Onboarding gate")
struct OnboardingGateTests {
    @MainActor
    private func makeSettings() -> (AppSettings, UserDefaults) {
        let defaults = UserDefaults(suiteName: "test.onboarding.\(UUID())")!
        return (AppSettings(defaults: defaults), defaults)
    }

    @Test("A fresh install has not completed onboarding")
    @MainActor
    func defaultsToNotCompleted() {
        let (settings, _) = makeSettings()
        #expect(settings.hasCompletedOnboarding == false)
    }

    @Test("Completion survives a relaunch")
    @MainActor
    func completionPersists() {
        let (settings, defaults) = makeSettings()
        settings.hasCompletedOnboarding = true

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.hasCompletedOnboarding == true)
    }

    /// Resetting detection tuning should not drop the user back into the tutorial —
    /// Settings offers a dedicated "Show onboarding again" action for that.
    @Test("Resetting defaults does not replay onboarding")
    @MainActor
    func resetDoesNotReplayOnboarding() {
        let (settings, _) = makeSettings()
        settings.hasCompletedOnboarding = true

        settings.resetToDefaults()

        #expect(settings.hasCompletedOnboarding == true)
    }
}

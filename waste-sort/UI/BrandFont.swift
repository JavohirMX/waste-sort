import CoreText
import SwiftUI
import UIKit

/// Brand typography. Display headings use Cheltenham; body copy stays on SF Pro so it matches
/// the rest of the app.
///
/// The bundled face is **Cheltenham Classic** (`Resources/Fonts/`), an open revival under the SIL
/// Open Font License 1.1 — see the `OFL.txt` beside it. It stands in for the ITC Cheltenham named
/// in the design, which is an Adobe-copyrighted commercial font that cannot be redistributed
/// inside an app binary without a licence.
///
/// Fonts are registered at runtime rather than through `UIAppFonts` because the target
/// generates its Info.plist from build settings and has no plist file to add the key to.
enum BrandFont {
    private static var didRegister = false
    private static var displayFontName: String?

    /// Registers every font bundled with the app. Safe to call more than once.
    static func register() {
        guard !didRegister else { return }
        didRegister = true

        for ext in ["otf", "ttf"] {
            for url in Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [] {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }

        displayFontName = resolveDisplayFontName()
    }

    /// Cheltenham Bold at a fixed size. Falls back to New York (the system serif) when the
    /// font file is not bundled, so the app still builds and renders sensibly without it.
    static func display(_ size: CGFloat) -> Font {
        guard let displayFontName else {
            return .system(size: size, weight: .bold, design: .serif)
        }
        return .custom(displayFontName, fixedSize: size)
    }

    /// SF Pro at a fixed size. Sizes come straight from the design, which already accounts
    /// for the reading distance of a wall-mounted kiosk, so Dynamic Type is not applied.
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Picks the bold face of whichever Cheltenham family got registered.
    private static func resolveDisplayFontName() -> String? {
        guard let family = UIFont.familyNames.first(where: {
            $0.localizedCaseInsensitiveContains("cheltenham")
        }) else {
            return nil
        }

        let names = UIFont.fontNames(forFamilyName: family)
        return names.first { $0.localizedCaseInsensitiveContains("bold") } ?? names.first
    }
}

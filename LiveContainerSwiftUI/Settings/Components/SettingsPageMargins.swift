//
//  SettingsPageMargins.swift
//  LiveContainerSwiftUI
//

import SwiftUI
import UIKit

/// The space around the cards of a page of Settings whose counterpart in the
/// Settings app is drawn with UIKit, such as General, Developer and each
/// app's page: UIKit's margins at the sides, which differ from SwiftUI's
/// (wider on larger iPhones, narrower in the iPad's detail column), and its
/// smaller gap above the first card. The Settings app's own list and its
/// newer pages, such as Apps, keep SwiftUI's.
struct SettingsPageMargins: ViewModifier {
    /// Whether the page takes UIKit's margins on iPad too, as it does in
    /// Settings' detail column.
    let isOnPad: Bool

    /// How wide the page is, which UIKit's margins depend on.

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *), isOnPad || SharedModel.isPhone {
            content
                .contentMargins(.top, SettingsDesign.uiKitPageTopMargin, for: .scrollContent)
                .environment(\.isSettingsPageSpacedAsUIKit, true)
        } else {
            content
        }
    }
}

extension View {
    /// Spaces a page's cards as the Settings app's UIKit pages are spaced, on
    /// iPhone and, unless `isOnPad` is false, on iPad.
    func settingsPageMargins(isOnPad: Bool = true) -> some View {
        modifier(SettingsPageMargins(isOnPad: isOnPad))
    }

    /// Places a section's header as the Settings app's UIKit pages do, on a
    /// page spaced as they are: a little lower under the card above, and
    /// closer over its own card than SwiftUI puts it. Elsewhere it leaves
    /// the header as it is.
    func settingsSectionHeader() -> some View {
        modifier(SettingsSectionHeader())
    }
}

/// A section's header placed as UIKit places it, where its page is spaced
/// as UIKit spaces it.
private struct SettingsSectionHeader: ViewModifier {
    @Environment(\.isSettingsPageSpacedAsUIKit) private var isSpacedAsUIKit

    func body(content: Content) -> some View {
        if isSpacedAsUIKit {
            content
                .padding(.top, SettingsDesign.uiKitHeaderLowering)
                .padding(.bottom, -SettingsDesign.uiKitHeaderCardRaise)
        } else {
            content
        }
    }
}

extension EnvironmentValues {
    /// Whether the page is spaced as the Settings app's UIKit pages are, so
    /// its section headers are placed as theirs are.
    @Entry var isSettingsPageSpacedAsUIKit = false
}

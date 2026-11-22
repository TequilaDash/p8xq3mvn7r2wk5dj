//
//  SettingsPageMargins.swift
//  LiveContainerSwiftUI
//

import SwiftUI

/// Retains the smaller top gap and section-header spacing of UIKit-style
/// Settings pages. Horizontal card margins belong solely to the native
/// inset-grouped List (or grouped Form), including in a split-view detail.
struct SettingsPageMargins: ViewModifier {
    /// Whether the page takes the top/header adjustments on iPad too.
    let isOnPad: Bool

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
    /// Adjusts a page's top/header spacing without overriding native side
    /// margins, on iPhone and, unless `isOnPad` is false, on iPad.
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



//
//  HomeButton.swift
//  LiveContainerSwiftUI
//

import SwiftUI

/// zContainer's stand-in for the iPhone's Home button: a round glass button
/// with AssistiveTouch's rings that does what pressing Home does. It looks the
/// same over the wallpaper, over Settings in light or dark mode, and
/// over apps, where TweakLoader draws the same button in UIKit.
struct HomeButton: View {
    /// What pressing it does, which is HomeScreenModel's `goHome()`.
    let action: () -> Void
    // The global overlay uses the rings alone; ordinary Home buttons keep glass.
    var showsGlass = true

    /// Counts the presses, so each one plays a light tap.
    @State private var presses = 0

    var body: some View {
        Button(action: press) {
            Group {
                if showsGlass {
                    buttonLabel.homeButtonGlass()
                } else {
                    buttonLabel
                }
            }
            .contentShape(.circle)
        }
        .buttonStyle(HomeButtonPressStyle(showsGlass: showsGlass))
        .sensoryFeedback(.impact(weight: .light), trigger: presses)
        .accessibilityHint("zc.home.homeButtonHint".loc)
    }

    private var buttonLabel: some View {
        Label {
            Text("zc.home.homeButton".loc)
        } icon: {
            HomeButtonGlyph()
        }
        .labelStyle(.iconOnly)
        .frame(width: HomeDesign.homeButtonSize, height: HomeDesign.homeButtonSize)
    }

    private func press() {
        presses += 1
        action()
    }
}

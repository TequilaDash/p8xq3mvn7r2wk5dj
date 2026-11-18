@import UIKit;

NS_ASSUME_NONNULL_BEGIN

// Puts the Home button over an app zContainer runs, and takes the person back
// to zContainer when they press it. zContainer turned into the app when it
// opened it, so going back means opening zContainer again with no app chosen:
// LCSharedUtils' launchToGuestAppWithClassicMode:, as the Home Screen uses to
// open apps, which zContainer's launch takes as a request for its own screens.
// First it tells the app it is going to the background (LCAppDeparture), as
// pressing Home on the iPhone does, so the app can save before it ends.
//
// TweakLoader starts it in every app zContainer runs itself. It stays out of
// apps in multitask windows (LiveProcess), which zContainer's windows already
// frame, and out of apps whose settings turn the Home button off.
@interface LCHomeButtonController : NSObject

// The one controller of this app's process.
@property (class, nonatomic, readonly) LCHomeButtonController *sharedController;

// Shows the button as soon as the app's screen is up, and again on whichever
// screen the app comes back to.
- (void)start;

// Fallback edge-swipe tracking from UIApplication's event stream. This is
// independent of the overlay window's gesture recognizers, so system gesture
// delivery cannot silently disable the user's "global" setting.
- (void)handleApplicationEvent:(UIEvent *)event;

@end

// Reads an experimental setting from the app group; used by the button
// controller and the button view so settings apply when the window appears.
NSString *LCHomeButtonSetting(NSString *key);
NSNumber *LCHomeButtonNumberSetting(NSString *key);
BOOL LCHomeButtonBoolSetting(NSString *key, BOOL fallback);

NS_ASSUME_NONNULL_END

@import UIKit;

NS_ASSUME_NONNULL_BEGIN

// The Home button window's root view controller. It keeps the button against
// an edge of the screen, lets it be dragged or flung to another place like
// AssistiveTouch, dims it after a few seconds without a touch, and leaves
// rotation, the status bar, the Home indicator and the screen edge gestures to
// the app underneath. Optional downward edge swipes use this same window.
@interface LCHomeButtonViewController : UIViewController

// Called when the button is pressed.
@property (nonatomic, copy, nullable) void (^pressHandler)(void);

// 侧边下滑 (实验性): 向下拖动超过阈值并松手后调用; 取消时快照回弹, 按键留在原位.
@property (nonatomic) BOOL edgeSwipeEnabled;
@property (nonatomic, copy, nullable) void (^edgeHandler)(void);
// 侧边下滑全局应用但没有开启辅助触控时，只保留边缘手势，不显示按键。
@property (nonatomic) BOOL buttonHidden;

// Covers the app in black, as it closes to go back to zContainer, and calls
// `completion` once the screen is black.
- (void)fadeOutWithCompletion:(void (^)(void))completion;

// Takes the black cover away again, when zContainer didn't open after all.
- (void)fadeBackIn;

// Reads the current app-group settings and updates button/edge visibility.
- (void)reloadSettings;
// 把按键强制放回默认边缘位置；只在窗口几何被修复后调用。
- (void)resetPlacementToDefault;

@end

NS_ASSUME_NONNULL_END

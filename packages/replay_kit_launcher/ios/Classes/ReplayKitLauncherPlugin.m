#import "ReplayKitLauncherPlugin.h"
#import <ReplayKit/ReplayKit.h>
#import <UIKit/UIKit.h>

/// 取当前前台活跃窗口。
///
/// iOS 13 起 App 可能有多个 scene（多窗口），
/// `UIApplication.sharedApplication.keyWindow` 已被弃用且可能返回 nil，
/// 所以优先遍历 connectedScenes，最后才回退到旧 API。
static UIWindow *RKLKeyWindow(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            if (scene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) {
                    return window;
                }
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
}

/// 在视图子树里递归找第一个 UIButton。
///
/// 递归而不是只看一级子视图：系统那个按钮不保证挂在哪一层，
/// 只看 `picker.subviews` 很容易在系统版本变化后突然失效（而且是静默失效）。
static UIButton *RKLFindButton(UIView *root) {
    for (UIView *sub in root.subviews) {
        if ([sub isMemberOfClass:[UIButton class]]) {
            return (UIButton *)sub;
        }
        UIButton *found = RKLFindButton(sub);
        if (found) {
            return found;
        }
    }
    return nil;
}

@implementation ReplayKitLauncherPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    FlutterMethodChannel *channel =
        [FlutterMethodChannel methodChannelWithName:@"replay_kit_launcher"
                                    binaryMessenger:[registrar messenger]];
    ReplayKitLauncherPlugin *instance = [[ReplayKitLauncherPlugin alloc] init];
    [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if ([@"launchReplayKitBroadcast" isEqualToString:call.method]) {
        NSDictionary *args = [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : nil;
        [self launchReplayKitBroadcast:args[@"extensionName"] result:result];
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (void)launchReplayKitBroadcast:(NSString *)extensionName result:(FlutterResult)result {
    if (@available(iOS 12.0, *)) {
        // 占位即可：真正的按钮是系统在内部生成的子视图。
        RPSystemBroadcastPickerView *picker =
            [[RPSystemBroadcastPickerView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
        // 人声由主 App 的 TRTC 采集，这里不重复开麦，否则会重音
        picker.showsMicrophoneButton = NO;

        if (extensionName.length == 0) {
            result([FlutterError errorWithCode:@"EMPTY_EXTENSION_NAME"
                                       message:@"没有指定录屏扩展名（BroadcastExtension）"
                                       details:nil]);
            return;
        }

        // RPSystemBroadcastPickerView 只接受**扩展的 bundle identifier**。
        // 传错的表现是：系统弹窗能出来，但里面是空的，列不出任何扩展。
        // 这里从主 App 包的 PlugIns 目录反查，避免手工维护字符串再次写错。
        NSString *bundlePath = [[NSBundle mainBundle] pathForResource:extensionName
                                                              ofType:@"appex"
                                                         inDirectory:@"PlugIns"];
        if (bundlePath) {
            NSBundle *extBundle = [NSBundle bundleWithPath:bundlePath];
            if (extBundle.bundleIdentifier.length > 0) {
                picker.preferredExtension = extBundle.bundleIdentifier;
            }
        }

        // ── 路径 1（首选）：直接替用户点掉那个系统按钮，一步到位 ──
        // 这是遍历子视图的做法，Apple 并未承诺该结构稳定，
        // 所以下面保留了路径 2 作为兜底。
        // 先 layoutIfNeeded：子视图是系统在初始化/布局时创建的，
        // 不强制布局一次有可能一个都遍历不到。
        [picker layoutIfNeeded];
        UIButton *button = RKLFindButton(picker);
        if (button) {
            [button sendActionsForControlEvents:UIControlEventAllTouchEvents];
            result(@(YES));
            return;
        }

        // ── 路径 2（兜底）：把系统按钮显示到屏幕上，让用户点一下 ──
        UIWindow *window = RKLKeyWindow();
        if (window) {
            CGSize size = window.bounds.size;
            picker.center = CGPointMake(size.width / 2.0, size.height - 140.0);
            picker.autoresizingMask = UIViewAutoresizingFlexibleTopMargin |
                                      UIViewAutoresizingFlexibleLeftMargin |
                                      UIViewAutoresizingFlexibleRightMargin;
            [window addSubview:picker];
            // 别让一个系统按钮长期挂在界面上，8 秒后自动收走
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    [picker removeFromSuperview];
                });
            result(@(YES));
            return;
        }

        result([FlutterError errorWithCode:@"NO_WINDOW"
                                   message:@"找不到可用的窗口，无法弹出录屏选择器"
                                   details:nil]);
    } else {
        // iOS 11 没有 RPSystemBroadcastPickerView，
        // 只能引导用户自己去控制中心长按录屏按钮。
        result([FlutterError errorWithCode:@"NOT_AVAILABLE"
                                   message:@"系统级屏幕共享需要 iOS 12 及以上；"
                                           @"iOS 11 请从控制中心长按录屏按钮启动"
                                   details:nil]);
    }
}

@end

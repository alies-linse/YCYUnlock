#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <objc/runtime.h>

#pragma mark - 全局变量

static UIWindow *floatWindow;
static UIButton *floatBtn;

#pragma mark - 获取当前前台窗口

static UIWindow *YCYForegroundWindow(void) {
    if (@available(iOS 13.0, *)) {
        NSSet<UIScene *> *scenes =
            UIApplication.sharedApplication.connectedScenes;

        for (UIScene *scene in scenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }

            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }

            UIWindowScene *windowScene = (UIWindowScene *)scene;

            // 优先使用 Key Window
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) {
                    return window;
                }
            }

            // 没有 Key Window 时使用第一个可见窗口
            for (UIWindow *window in windowScene.windows) {
                if (!window.hidden && window.alpha > 0.0) {
                    return window;
                }
            }

            // 最后退回窗口列表第一个
            if (windowScene.windows.count > 0) {
                return windowScene.windows.firstObject;
            }
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

    // iOS 12 及以下兼容
    return UIApplication.sharedApplication.keyWindow;

#pragma clang diagnostic pop
}

#pragma mark - Toast

static void showToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = YCYForegroundWindow();

        if (!window) {
            NSLog(@"[YCYUnlock] 找不到当前前台 UIWindow");
            return;
        }

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"YCY Unlock"
                                                message:msg
                                         preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:
            [UIAlertAction actionWithTitle:@"OK"
                                     style:UIAlertActionStyleDefault
                                   handler:nil]];

        UIViewController *root = window.rootViewController;

        if (!root) {
            NSLog(@"[YCYUnlock] UIWindow 没有 rootViewController");
            return;
        }

        while (root.presentedViewController) {
            root = root.presentedViewController;
        }

        [root presentViewController:alert
                           animated:YES
                         completion:nil];
    });
}

#pragma mark - 功能入口

static void tryUnlock(void) {
    NSLog(@"[YCYUnlock] 功能按钮被点击");

    /*
     本版本仅保留安全的 UI / 日志功能。
     
     原来的候选 BLE 指令数组已经删除，
     避免 unused variable 编译错误。
     
     涉及绕过授权、重放开锁指令等逻辑不在这里实现。
    */

    showToast(@"功能入口正常运行");
}

#pragma mark - 悬浮按钮

static void createFloatButton(void) {

    if (floatWindow) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{

        if (floatWindow) {
            return;
        }

        CGRect frame = CGRectMake(30.0, 180.0, 64.0, 64.0);

        floatWindow = [[UIWindow alloc] initWithFrame:frame];

        floatWindow.windowLevel = UIWindowLevelAlert + 100.0;
        floatWindow.backgroundColor = UIColor.clearColor;
        floatWindow.hidden = NO;
        floatWindow.userInteractionEnabled = YES;

        floatBtn = [UIButton buttonWithType:UIButtonTypeCustom];

        floatBtn.frame = CGRectMake(0.0, 0.0, 64.0, 64.0);

        floatBtn.backgroundColor =
            [UIColor.systemRedColor colorWithAlphaComponent:0.9];

        floatBtn.layer.cornerRadius = 32.0;
        floatBtn.layer.masksToBounds = YES;

        [floatBtn setTitle:@"开锁"
                  forState:UIControlStateNormal];

        floatBtn.titleLabel.font =
            [UIFont boldSystemFontOfSize:15.0];

        [floatBtn setTitleColor:UIColor.whiteColor
                       forState:UIControlStateNormal];

        [floatBtn addTarget:NSClassFromString(@"YCYUnlockHelper")
                     action:@selector(onUnlockTapped)
           forControlEvents:UIControlEventTouchUpInside];

        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc]
                initWithTarget:NSClassFromString(@"YCYUnlockHelper")
                        action:@selector(onPan:)];

        [floatBtn addGestureRecognizer:pan];

        [floatWindow addSubview:floatBtn];

        [floatWindow makeKeyAndVisible];

        NSLog(@"[YCYUnlock] 悬浮按钮创建成功");
    });
}

#pragma mark - Helper

@interface YCYUnlockHelper : NSObject
@end

@implementation YCYUnlockHelper

+ (void)onUnlockTapped {
    tryUnlock();
}

+ (void)onPan:(UIPanGestureRecognizer *)pan {

    if (!floatWindow) {
        return;
    }

    CGPoint translation =
        [pan translationInView:floatWindow];

    CGPoint center = floatWindow.center;

    center.x += translation.x;
    center.y += translation.y;

    floatWindow.center = center;

    [pan setTranslation:CGPointZero
               inView:floatWindow];
}

@end

#pragma mark - CoreBluetooth 日志

%hook CBPeripheral

- (void)writeValue:(NSData *)data
 forCharacteristic:(CBCharacteristic *)characteristic
              type:(CBCharacteristicWriteType)type {

    NSString *uuid =
        characteristic.UUID.UUIDString.uppercaseString;

    NSLog(@"[YCYUnlock] BLE write");
    NSLog(@"[YCYUnlock] Characteristic: %@", uuid);
    NSLog(@"[YCYUnlock] Data: %@", data);
    NSLog(@"[YCYUnlock] Write Type: %ld", (long)type);

    %orig;
}

%end

#pragma mark - 启动

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {

    %orig;

    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(4 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{

                createFloatButton();
            });
    });
}

%end

#pragma mark - Constructor

%ctor {

    NSLog(@"[YCYUnlock] ==========================");
    NSLog(@"[YCYUnlock] Tweak loaded");
    NSLog(@"[YCYUnlock] ==========================");
}

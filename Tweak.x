#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#pragma mark - 穿透 UIWindow

@interface YCYOverlayWindow : UIWindow
@end

@implementation YCYOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];

    // 只有实际点击到按钮/按钮子视图时才拦截
    if (hitView == self || hitView == self.rootViewController.view) {
        return nil;
    }

    return hitView;
}

@end

#pragma mark - 全局

static YCYOverlayWindow *testWindow;
static UIButton *testButton;

#pragma mark - 创建悬浮按钮

static void YCYShowTestWindow(void) {

    dispatch_async(dispatch_get_main_queue(), ^{

        if (testWindow) {
            testWindow.hidden = NO;
            return;
        }

        CGRect screenFrame = [UIScreen mainScreen].bounds;

        testWindow = [[YCYOverlayWindow alloc] initWithFrame:screenFrame];

        testWindow.windowLevel = UIWindowLevelAlert + 100;
        testWindow.backgroundColor = [UIColor clearColor];
        testWindow.opaque = NO;

        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = [UIColor clearColor];

        testButton = [UIButton buttonWithType:UIButtonTypeSystem];

        testButton.frame = CGRectMake(30, 150, 120, 55);

        testButton.backgroundColor = [UIColor systemBlueColor];

        [testButton setTitle:@"YCY TEST"
                    forState:UIControlStateNormal];

        [testButton setTitleColor:[UIColor whiteColor]
                         forState:UIControlStateNormal];

        testButton.layer.cornerRadius = 12;

        [testButton addTarget:NSClassFromString(@"YCYUnlockHelper")
                       action:@selector(testButtonClicked:)
             forControlEvents:UIControlEventTouchUpInside];

        [vc.view addSubview:testButton];

        testWindow.rootViewController = vc;

        testWindow.hidden = NO;

        NSLog(@"[YCYUnlock] Overlay window created");

    });
}

#pragma mark - 测试按钮

@interface YCYUnlockHelper : NSObject
@end

@implementation YCYUnlockHelper

+ (void)testButtonClicked:(UIButton *)sender {

    NSLog(@"[YCYUnlock] TEST BUTTON CLICKED");

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"YCYUnlock"
                                             message:@"悬浮窗工作正常"
                                      preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:
        [UIAlertAction actionWithTitle:@"确定"
                                 style:UIAlertActionStyleDefault
                               handler:nil]];

    UIWindow *keyWindow = nil;

    if (@available(iOS 13.0, *)) {

        for (UIScene *scene in
             [UIApplication sharedApplication].connectedScenes) {

            if (scene.activationState ==
                UISceneActivationStateForegroundActive) {

                UIWindowScene *windowScene =
                    (UIWindowScene *)scene;

                for (UIWindow *window in windowScene.windows) {

                    if (window.isKeyWindow) {
                        keyWindow = window;
                        break;
                    }
                }
            }

            if (keyWindow)
                break;
        }
    }

    if (!keyWindow)
        keyWindow = [UIApplication sharedApplication].keyWindow;

    UIViewController *vc =
        keyWindow.rootViewController;

    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }

    [vc presentViewController:alert
                     animated:YES
                   completion:nil];
}

@end

#pragma mark - App 生命周期

%hook UIApplication

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    NSLog(@"[YCYUnlock] didFinishLaunching");

    BOOL result =
        %orig(application, launchOptions);

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
            YCYShowTestWindow();
        }
    );

    return result;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {

    NSLog(@"[YCYUnlock] applicationDidBecomeActive");

    %orig;

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
            YCYShowTestWindow();
        }
    );
}

%end

#pragma mark - Tweak 加载

%ctor {

    NSLog(@"[YCYUnlock] ===== TWEAK LOADED =====");

}

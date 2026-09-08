#import <UIKit/UIKit.h>

static UIWindow *testWindow;

static void YCYShowTestWindow(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (testWindow) {
            testWindow.hidden = NO;
            return;
        }

        CGRect frame = [UIScreen mainScreen].bounds;

        testWindow = [[UIWindow alloc] initWithFrame:frame];
        testWindow.windowLevel = UIWindowLevelAlert + 100;
        testWindow.backgroundColor = [UIColor clearColor];

        UIViewController *vc = [UIViewController new];

        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = CGRectMake(30, 150, 120, 55);
        button.backgroundColor = [UIColor systemBlueColor];
        [button setTitle:@"YCY TEST" forState:UIControlStateNormal];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        button.layer.cornerRadius = 12;

        [vc.view addSubview:button];

        testWindow.rootViewController = vc;
        testWindow.hidden = NO;

        NSLog(@"[YCYUnlock] TEST WINDOW CREATED");
    });
}

%hook UIApplication

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    NSLog(@"[YCYUnlock] didFinishLaunching");

    BOOL result =
        %orig(application, launchOptions);

    YCYShowTestWindow();

    return result;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {

    NSLog(@"[YCYUnlock] applicationDidBecomeActive");

    %orig;

    YCYShowTestWindow();
}

%end

%ctor {
    NSLog(@"[YCYUnlock] ===== TWEAK LOADED =====");

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
            NSLog(@"[YCYUnlock] 3 second test");
            YCYShowTestWindow();
        }
    );
}

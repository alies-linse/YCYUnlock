```objc
#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <QuartzCore/QuartzCore.h>

#pragma mark - 全局

static UIWindow *floatWindow;
static UIButton *floatButton;

static NSMutableArray<NSString *> *bleLogs;
static NSLock *bleLogLock;

static BOOL monitorEnabled = YES;

#pragma mark - 日志

static void YCYInitLogger(void) {
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        bleLogs = [NSMutableArray array];
        bleLogLock = [[NSLock alloc] init];

        NSLog(@"[YCYUnlock] Logger initialized");
    });
}

static void YCYLog(NSString *format, ...) {

    YCYInitLogger();

    va_list args;
    va_start(args, format);

    NSString *message =
        [[NSString alloc] initWithFormat:format arguments:args];

    va_end(args);

    NSString *line =
        [NSString stringWithFormat:@"[YCYUnlock] %@", message];

    NSLog(@"%@", line);

    [bleLogLock lock];

    [bleLogs addObject:line];

    // 防止日志无限增长
    if (bleLogs.count > 500) {
        [bleLogs removeObjectsInRange:
            NSMakeRange(0, bleLogs.count - 500)];
    }

    [bleLogLock unlock];
}

static NSString *YCYHexString(NSData *data) {

    if (!data || data.length == 0) {
        return @"<empty>";
    }

    const unsigned char *bytes =
        data.bytes;

    NSMutableString *result =
        [NSMutableString string];

    for (NSUInteger i = 0; i < data.length; i++) {

        [result appendFormat:@"%02X", bytes[i]];

        if (i + 1 < data.length) {
            [result appendString:@" "];
        }
    }

    return result;
}

static NSString *YCYUUIDString(NSUUID *uuid) {

    if (!uuid) {
        return @"<nil>";
    }

    return uuid.UUIDString ?: @"<unknown>";
}

static NSString *YCYPeripheralName(CBPeripheral *peripheral) {

    if (!peripheral) {
        return @"<nil>";
    }

    return peripheral.name.length
        ? peripheral.name
        : @"<Unnamed Peripheral>";
}

static NSString *YCYProperties(CBCharacteristic *characteristic) {

    CBCharacteristicProperties p =
        characteristic.properties;

    NSMutableArray *items =
        [NSMutableArray array];

    if (p & CBCharacteristicPropertyBroadcast)
        [items addObject:@"Broadcast"];

    if (p & CBCharacteristicPropertyRead)
        [items addObject:@"Read"];

    if (p & CBCharacteristicPropertyWriteWithoutResponse)
        [items addObject:@"WriteWithoutResponse"];

    if (p & CBCharacteristicPropertyWrite)
        [items addObject:@"Write"];

    if (p & CBCharacteristicPropertyNotify)
        [items addObject:@"Notify"];

    if (p & CBCharacteristicPropertyIndicate)
        [items addObject:@"Indicate"];

    if (p & CBCharacteristicPropertyAuthenticatedSignedWrites)
        [items addObject:@"AuthenticatedSignedWrites"];

    if (p & CBCharacteristicPropertyExtendedProperties)
        [items addObject:@"ExtendedProperties"];

    if (p & CBCharacteristicPropertyNotifyEncryptionRequired)
        [items addObject:@"NotifyEncryptionRequired"];

    if (p & CBCharacteristicPropertyIndicateEncryptionRequired)
        [items addObject:@"IndicateEncryptionRequired"];

    return items.count
        ? [items componentsJoinedByString:@" | "]
        : @"None";
}

#pragma mark - 获取当前 App Window

static UIWindow *YCYCurrentAppWindow(void) {

    UIApplication *application =
        [UIApplication sharedApplication];

    if (@available(iOS 13.0, *)) {

        for (UIScene *scene
             in application.connectedScenes) {

            if (scene.activationState !=
                UISceneActivationStateForegroundActive) {
                continue;
            }

            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }

            UIWindowScene *windowScene =
                (UIWindowScene *)scene;

            // 第一优先级：当前 Key Window
            for (UIWindow *window
                 in windowScene.windows) {

                if (window.isKeyWindow &&
                    !window.hidden &&
                    window.alpha > 0.0 &&
                    window.windowLevel ==
                        UIWindowLevelNormal) {

                    return window;
                }
            }

            // 第二优先级：普通可见窗口
            for (UIWindow *window
                 in windowScene.windows) {

                if (!window.hidden &&
                    window.alpha > 0.0 &&
                    window.windowLevel ==
                        UIWindowLevelNormal) {

                    return window;
                }
            }
        }
    }

    return nil;
}

#pragma mark - 日志查看

static void YCYShowLogs(void) {

    dispatch_async(dispatch_get_main_queue(), ^{

        UIWindow *appWindow =
            YCYCurrentAppWindow();

        if (!appWindow) {
            YCYLog(@"Cannot find application window");
            return;
        }

        NSMutableString *text =
            [NSMutableString string];

        [bleLogLock lock];

        if (bleLogs.count == 0) {

            [text appendString:@"暂无 BLE 日志"];

        } else {

            for (NSString *line in bleLogs) {
                [text appendFormat:@"%@\n", line];
            }
        }

        [bleLogLock unlock];

        UIAlertController *alert =
            [UIAlertController
                alertControllerWithTitle:@"YCY BLE Monitor"
                                 message:text
                          preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:
            [UIAlertAction
                actionWithTitle:@"关闭"
                          style:UIAlertActionStyleDefault
                        handler:nil]];

        UIViewController *vc =
            appWindow.rootViewController;

        while (vc.presentedViewController) {
            vc = vc.presentedViewController;
        }

        [vc presentViewController:alert
                         animated:YES
                       completion:nil];
    });
}

#pragma mark - 清空日志

static void YCYClearLogs(void) {

    [bleLogLock lock];

    [bleLogs removeAllObjects];

    [bleLogLock unlock];

    YCYLog(@"Logs cleared");
}

#pragma mark - 复制日志

static void YCYCopyLogs(void) {

    [bleLogLock lock];

    NSString *text =
        [bleLogs componentsJoinedByString:@"\n"];

    [bleLogLock unlock];

    UIPasteboard.generalPasteboard.string = text;

    YCYLog(@"Logs copied to clipboard");
}

#pragma mark - 悬浮窗

@interface YCYOverlayWindow : UIWindow
@end

@implementation YCYOverlayWindow

/*
 * 关键：
 * 悬浮窗只有按钮区域拦截触摸，
 * 其它区域返回 nil，让触摸继续传给原 App。
 */
- (UIView *)hitTest:(CGPoint)point
          withEvent:(UIEvent *)event {

    UIView *hitView =
        [super hitTest:point withEvent:event];

    if (hitView == self ||
        hitView == self.rootViewController.view) {

        return nil;
    }

    return hitView;
}

@end

#pragma mark - 悬浮按钮操作

static void YCYButtonAction(UIButton *sender) {

    UIAlertController *menu =
        [UIAlertController
            alertControllerWithTitle:@"YCY BLE Monitor"
                             message:
        [NSString stringWithFormat:
            @"监控状态：%@",
            monitorEnabled ? @"开启" : @"关闭"]
                      preferredStyle:UIAlertControllerStyleActionSheet];

    [menu addAction:
        [UIAlertAction
            actionWithTitle:@"查看 BLE 日志"
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *action) {
                        YCYShowLogs();
                    }]];

    [menu addAction:
        [UIAlertAction
            actionWithTitle:@"复制 BLE 日志"
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *action) {
                        YCYCopyLogs();
                    }]];

    [menu addAction:
        [UIAlertAction
            actionWithTitle:@"清空日志"
                      style:UIAlertActionStyleDestructive
                    handler:^(UIAlertAction *action) {
                        YCYClearLogs();
                    }]];

    [menu addAction:
        [UIAlertAction
            actionWithTitle:
                monitorEnabled
                ? @"关闭监控"
                : @"开启监控"
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *action) {

                        monitorEnabled =
                            !monitorEnabled;

                        YCYLog(
                            @"Monitor %@",
                            monitorEnabled
                                ? @"enabled"
                                : @"disabled");
                    }]];

    [menu addAction:
        [UIAlertAction
            actionWithTitle:@"取消"
                      style:UIAlertActionStyleCancel
                    handler:nil]];

    UIWindow *appWindow =
        YCYCurrentAppWindow();

    if (!appWindow) {
        YCYLog(@"Cannot find application window");
        return;
    }

    // 防止 ActionSheet 在某些 iPad 环境下崩溃
    if (menu.popoverPresentationController) {
        menu.popoverPresentationController.sourceView =
            sender;

        menu.popoverPresentationController.sourceRect =
            sender.bounds;
    }

    UIViewController *vc =
        appWindow.rootViewController;

    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }

    [vc presentViewController:menu
                     animated:YES
                   completion:nil];
}

#pragma mark - 创建悬浮窗

static void YCYCreateFloatingButton(void) {

    dispatch_async(dispatch_get_main_queue(), ^{

        if (floatWindow) {

            floatWindow.hidden = NO;

            return;
        }

        UIScreen *screen =
            [UIScreen mainScreen];

        floatWindow =
            [[YCYOverlayWindow alloc]
                initWithFrame:screen.bounds];

        floatWindow.windowLevel =
            UIWindowLevelAlert + 100;

        floatWindow.backgroundColor =
            [UIColor clearColor];

        floatWindow.opaque = NO;

        UIViewController *vc =
            [UIViewController new];

        vc.view.backgroundColor =
            [UIColor clearColor];

        floatButton =
            [UIButton buttonWithType:UIButtonTypeSystem];

        floatButton.frame =
            CGRectMake(25, 150, 110, 50);

        floatButton.backgroundColor =
            [UIColor systemBlueColor];

        [floatButton
            setTitle:@"YCY BLE"
            forState:UIControlStateNormal];

        [floatButton
            setTitleColor:[UIColor whiteColor]
                 forState:UIControlStateNormal];

        floatButton.layer.cornerRadius = 12.0;

        floatButton.layer.shadowOpacity = 0.25;
        floatButton.layer.shadowRadius = 5.0;
        floatButton.layer.shadowOffset =
            CGSizeMake(0, 2);

        [floatButton
            addTarget:
                NSClassFromString(@"YCYUnlockHelper")
            action:@selector(ycyButtonClicked:)
            forControlEvents:
                UIControlEventTouchUpInside];

        [vc.view addSubview:floatButton];

        floatWindow.rootViewController = vc;

        floatWindow.hidden = NO;

        YCYLog(@"Floating button created");
    });
}

#pragma mark - Helper

@interface YCYUnlockHelper : NSObject
@end

@implementation YCYUnlockHelper

+ (void)ycyButtonClicked:(UIButton *)sender {
    YCYButtonAction(sender);
}

@end

#pragma mark - CoreBluetooth Monitor

%hook CBCentralManager

- (void)scanForPeripheralsWithServices:
        (NSArray<CBUUID *> *)serviceUUIDs
                            options:
        (NSDictionary<NSString *,id> *)options {

    if (monitorEnabled) {

        NSMutableArray *uuids =
            [NSMutableArray array];

        for (CBUUID *uuid in serviceUUIDs) {
            [uuids addObject:uuid.UUIDString];
        }

        YCYLog(
            @"Central scanForPeripherals services=%@ options=%@",
            uuids,
            options);
    }

    %orig;
}

- (void)stopScan {

    if (monitorEnabled) {
        YCYLog(@"Central stopScan");
    }

    %orig;
}

- (void)connectPeripheral:
        (CBPeripheral *)peripheral
                  options:
        (NSDictionary<NSString *,id> *)options {

    if (monitorEnabled) {

        YCYLog(
            @"Central connectPeripheral name=%@ UUID=%@",
            YCYPeripheralName(peripheral),
            YCYUUIDString(peripheral.identifier));
    }

    %orig;
}

- (void)cancelPeripheralConnection:
        (CBPeripheral *)peripheral {

    if (monitorEnabled) {

        YCYLog(
            @"Central cancelPeripheralConnection name=%@ UUID=%@",
            YCYPeripheralName(peripheral),
            YCYUUIDString(peripheral.identifier));
    }

    %orig;
}

%end

#pragma mark - CBPeripheral Monitor

%hook CBPeripheral

- (void)setDelegate:(id<CBPeripheralDelegate>)delegate {

    if (monitorEnabled) {

        YCYLog(
            @"Peripheral %@ setDelegate class=%@",
            YCYPeripheralName(self),
            delegate
                ? NSStringFromClass([delegate class])
                : @"<nil>");
    }

    %orig;
}

- (void)discoverServices:
        (NSArray<CBUUID *> *)serviceUUIDs {

    if (monitorEnabled) {

        NSMutableArray *uuids =
            [NSMutableArray array];

        for (CBUUID *uuid in serviceUUIDs) {
            [uuids addObject:uuid.UUIDString];
        }

        YCYLog(
            @"Peripheral %@ discoverServices=%@",
            YCYPeripheralName(self),
            uuids);
    }

    %orig;
}

- (void)discoverCharacteristics:
        (NSArray<CBUUID *> *)characteristicUUIDs
                         forService:
        (CBService *)service {

    if (monitorEnabled) {

        NSMutableArray *uuids =
            [NSMutableArray array];

        for (CBUUID *uuid in characteristicUUIDs) {
            [uuids addObject:uuid.UUIDString];
        }

        YCYLog(
            @"Peripheral %@ discoverCharacteristics service=%@ chars=%@",
            YCYPeripheralName(self),
            service.UUID.UUIDString,
            uuids);
    }

    %orig;
}

- (void)readValueForCharacteristic:
        (CBCharacteristic *)characteristic {

    if (monitorEnabled) {

        YCYLog(
            @"Peripheral %@ READ service=%@ characteristic=%@",
            YCYPeripheralName(self),
            characteristic.service.UUID.UUIDString,
            characteristic.UUID.UUIDString);
    }

    %orig;
}

- (void)setNotifyValue:
        (BOOL)enabled
    forCharacteristic:
        (CBCharacteristic *)characteristic {

    if (monitorEnabled) {

        YCYLog(
            @"Peripheral %@ NOTIFY %@ service=%@ characteristic=%@",
            YCYPeripheralName(self),
            enabled ? @"ON" : @"OFF",
            characteristic.service.UUID.UUIDString,
            characteristic.UUID.UUIDString);
    }

    %orig;
}

- (void)writeValue:
        (NSData *)data
forCharacteristic:
        (CBCharacteristic *)characteristic
             type:
        (CBCharacteristicWriteType)type {

    if (monitorEnabled) {

        NSString *writeType =
            type ==
                CBCharacteristicWriteWithResponse
                ? @"WithResponse"
                : @"WithoutResponse";

        YCYLog(
            @"Peripheral %@ WRITE service=%@ characteristic=%@ properties=[%@] type=%@ length=%lu HEX=%@",
            YCYPeripheralName(self),
            characteristic.service.UUID.UUIDString,
            characteristic.UUID.UUIDString,
            YCYProperties(characteristic),
            writeType,
            (unsigned long)data.length,
            YCYHexString(data));
    }

    %orig;
}

%end

#pragma mark - App 生命周期

%hook UIApplication

- (BOOL)application:
            (UIApplication *)application
    didFinishLaunchingWithOptions:
            (NSDictionary *)launchOptions {

    YCYInitLogger();

    YCYLog(@"didFinishLaunching");

    BOOL result =
        %orig(application, launchOptions);

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            2 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{

            YCYCreateFloatingButton();
        });

    return result;
}

- (void)applicationDidBecomeActive:
            (UIApplication *)application {

    YCYInitLogger();

    YCYLog(@"applicationDidBecomeActive");

    %orig;

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            500 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{

            YCYCreateFloatingButton();
        });
}

%end

#pragma mark - Tweak Constructor

%ctor {

    YCYInitLogger();

    YCYLog(@"==============================");
    YCYLog(@"YCYUnlock Tweak Loaded");
    YCYLog(@"BLE Monitor Ready");
    YCYLog(@"==============================");
}
```

#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#pragma mark - Global

static UIWindow *floatWindow = nil;
static UIButton *floatBtn = nil;

static NSMutableArray<NSString *> *bleLogs = nil;
static NSLock *bleLogLock = nil;

static BOOL monitorEnabled = YES;

#pragma mark - Logging

static void YCYInitLogger(void) {
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        bleLogs = [NSMutableArray array];
        bleLogLock = [[NSLock alloc] init];
    });
}

static NSString *YCYHexString(NSData *data) {

    if (!data || data.length == 0) {
        return @"<empty>";
    }

    const unsigned char *bytes =
        (const unsigned char *)data.bytes;

    NSMutableString *result =
        [NSMutableString stringWithCapacity:data.length * 3];

    for (NSUInteger i = 0; i < data.length; i++) {

        [result appendFormat:@"%02X", bytes[i]];

        if (i + 1 < data.length) {
            [result appendString:@" "];
        }
    }

    return result;
}

static void YCYLog(NSString *format, ...) {

    YCYInitLogger();

    va_list args;
    va_start(args, format);

    NSString *message =
        [[NSString alloc] initWithFormat:format
                              arguments:args];

    va_end(args);

    NSDateFormatter *formatter =
        [[NSDateFormatter alloc] init];

    formatter.dateFormat = @"HH:mm:ss.SSS";

    NSString *time =
        [formatter stringFromDate:[NSDate date]];

    NSString *line =
        [NSString stringWithFormat:@"[%@] %@",
         time,
         message];

    NSLog(@"[YCYUnlock] %@", line);

    [bleLogLock lock];

    [bleLogs addObject:line];

    // 最多保存 2000 条
    if (bleLogs.count > 2000) {

        [bleLogs removeObjectsInRange:
            NSMakeRange(0, bleLogs.count - 2000)];
    }

    [bleLogLock unlock];
}

static NSString *YCYSnapshotLogs(void) {

    YCYInitLogger();

    [bleLogLock lock];

    NSString *text =
        [bleLogs componentsJoinedByString:@"\n"];

    [bleLogLock unlock];

    return text ?: @"";
}

static void YCYClearLogs(void) {

    YCYInitLogger();

    [bleLogLock lock];
    [bleLogs removeAllObjects];
    [bleLogLock unlock];

    YCYLog(@"========== LOG CLEARED ==========");
}

#pragma mark - BLE Description

static NSString *YCYPeripheralName(CBPeripheral *peripheral) {

    if (peripheral.name.length > 0) {
        return peripheral.name;
    }

    return @"<unnamed>";
}

static NSString *YCYCharacteristicProperties(
    CBCharacteristicProperties properties) {

    NSMutableArray *items =
        [NSMutableArray array];

    if (properties & CBCharacteristicPropertyBroadcast) {
        [items addObject:@"Broadcast"];
    }

    if (properties & CBCharacteristicPropertyRead) {
        [items addObject:@"Read"];
    }

    if (properties & CBCharacteristicPropertyWriteWithoutResponse) {
        [items addObject:@"WriteWithoutResponse"];
    }

    if (properties & CBCharacteristicPropertyWrite) {
        [items addObject:@"Write"];
    }

    if (properties & CBCharacteristicPropertyNotify) {
        [items addObject:@"Notify"];
    }

    if (properties & CBCharacteristicPropertyIndicate) {
        [items addObject:@"Indicate"];
    }

    if (properties & CBCharacteristicPropertyAuthenticatedSignedWrites) {
        [items addObject:@"AuthenticatedSignedWrites"];
    }

    if (properties & CBCharacteristicPropertyExtendedProperties) {
        [items addObject:@"ExtendedProperties"];
    }

    if (properties & CBCharacteristicPropertyNotifyEncryptionRequired) {
        [items addObject:@"NotifyEncryptionRequired"];
    }

    if (properties & CBCharacteristicPropertyIndicateEncryptionRequired) {
        [items addObject:@"IndicateEncryptionRequired"];
    }

    if (items.count == 0) {
        return @"None";
    }

    return [items componentsJoinedByString:@", "];
}

#pragma mark - Foreground Window

static UIWindow *YCYForegroundWindow(void) {

    if (@available(iOS 13.0, *)) {

        NSSet<UIScene *> *scenes =
            UIApplication.sharedApplication.connectedScenes;

        for (UIScene *scene in scenes) {

            if (scene.activationState !=
                UISceneActivationStateForegroundActive) {
                continue;
            }

            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }

            UIWindowScene *windowScene =
                (UIWindowScene *)scene;

            // 优先 Key Window
            for (UIWindow *window in windowScene.windows) {

                if (window.isKeyWindow) {
                    return window;
                }
            }

            // 再找正常可见窗口
            for (UIWindow *window in windowScene.windows) {

                if (!window.hidden &&
                    window.alpha > 0.0 &&
                    window.windowLevel == UIWindowLevelNormal) {

                    return window;
                }
            }

            if (windowScene.windows.count > 0) {
                return windowScene.windows.firstObject;
            }
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

    return UIApplication.sharedApplication.keyWindow;

#pragma clang diagnostic pop
}

#pragma mark - Toast

static void YCYToast(NSString *message) {

    dispatch_async(dispatch_get_main_queue(), ^{

        UIWindow *window =
            YCYForegroundWindow();

        if (!window) {
            return;
        }

        UIViewController *root =
            window.rootViewController;

        if (!root) {
            return;
        }

        while (root.presentedViewController) {
            root = root.presentedViewController;
        }

        UIAlertController *alert =
            [UIAlertController
                alertControllerWithTitle:@"YCY BLE Monitor"
                message:message
                preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:
            [UIAlertAction
                actionWithTitle:@"OK"
                style:UIAlertActionStyleDefault
                handler:nil]];

        [root presentViewController:alert
                           animated:YES
                         completion:nil];
    });
}

#pragma mark - Helper Interface

@interface YCYUnlockHelper : NSObject

+ (void)showMonitor;
+ (void)showLogs;
+ (void)clearLogs;
+ (void)copyLogs;
+ (void)onPan:(UIPanGestureRecognizer *)pan;

@end

#pragma mark - Floating Button

static void YCYCreateFloatButton(void) {

    dispatch_async(dispatch_get_main_queue(), ^{

        if (floatWindow) {
            return;
        }

        CGRect frame =
            CGRectMake(25.0, 180.0, 70.0, 70.0);

        floatWindow =
            [[UIWindow alloc] initWithFrame:frame];

        floatWindow.windowLevel =
            UIWindowLevelAlert + 100.0;

        floatWindow.backgroundColor =
            UIColor.clearColor;

        floatWindow.userInteractionEnabled = YES;

        // 不调用 makeKeyAndVisible，
        // 避免抢走 App 原来的 Key Window。
        floatWindow.hidden = NO;

        floatBtn =
            [UIButton buttonWithType:UIButtonTypeCustom];

        floatBtn.frame =
            CGRectMake(0, 0, 70, 70);

        floatBtn.backgroundColor =
            [UIColor.systemBlueColor
                colorWithAlphaComponent:0.92];

        floatBtn.layer.cornerRadius = 35.0;
        floatBtn.layer.masksToBounds = YES;

        [floatBtn setTitle:@"BLE"
                  forState:UIControlStateNormal];

        floatBtn.titleLabel.font =
            [UIFont boldSystemFontOfSize:15.0];

        [floatBtn setTitleColor:UIColor.whiteColor
                       forState:UIControlStateNormal];

        [floatBtn addTarget:NSClassFromString(@"YCYUnlockHelper")
                      action:@selector(showMonitor)
            forControlEvents:UIControlEventTouchUpInside];

        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc]
                initWithTarget:NSClassFromString(@"YCYUnlockHelper")
                        action:@selector(onPan:)];

        [floatBtn addGestureRecognizer:pan];

        [floatWindow addSubview:floatBtn];

        YCYLog(@"Floating BLE monitor button created");
    });
}

#pragma mark - Monitor UI

@implementation YCYUnlockHelper

+ (void)showMonitor {

    dispatch_async(dispatch_get_main_queue(), ^{

        UIWindow *window =
            YCYForegroundWindow();

        if (!window) {
            return;
        }

        UIViewController *root =
            window.rootViewController;

        if (!root) {
            return;
        }

        while (root.presentedViewController) {
            root = root.presentedViewController;
        }

        UIAlertController *menu =
            [UIAlertController
                alertControllerWithTitle:@"YCY BLE Monitor"
                message:@"BLE Diagnostics"
                preferredStyle:UIAlertControllerStyleAlert];

        [menu addAction:
            [UIAlertAction
                actionWithTitle:@"查看 BLE 日志"
                style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {

                    [self showLogs];
                }]];

        [menu addAction:
            [UIAlertAction
                actionWithTitle:@"清空日志"
                style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {

                    [self clearLogs];
                }]];

        [menu addAction:
            [UIAlertAction
                actionWithTitle:@"复制日志"
                style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {

                    [self copyLogs];
                }]];

        [menu addAction:
            [UIAlertAction
                actionWithTitle:
                    monitorEnabled
                        ? @"关闭监控"
                        : @"开启监控"
                style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {

                    monitorEnabled = !monitorEnabled;

                    YCYLog(@"BLE Monitor: %@",
                           monitorEnabled
                               ? @"ENABLED"
                               : @"DISABLED");

                    YCYToast(
                        monitorEnabled
                            ? @"BLE 监控已开启"
                            : @"BLE 监控已关闭"
                    );
                }]];

        [menu addAction:
            [UIAlertAction
                actionWithTitle:@"取消"
                style:UIAlertActionStyleCancel
                handler:nil]];

        [root presentViewController:menu
                           animated:YES
                         completion:nil];
    });
}

+ (void)showLogs {

    dispatch_async(dispatch_get_main_queue(), ^{

        UIWindow *window =
            YCYForegroundWindow();

        if (!window) {
            return;
        }

        UIViewController *root =
            window.rootViewController;

        if (!root) {
            return;
        }

        while (root.presentedViewController) {
            root = root.presentedViewController;
        }

        NSString *text =
            YCYSnapshotLogs();

        if (text.length == 0) {
            text = @"暂无 BLE 日志";
        }

        // UIAlertController 不适合显示无限长文本
        NSUInteger maxLength = 12000;

        if (text.length > maxLength) {

            text =
                [text substringFromIndex:
                    text.length - maxLength];
        }

        UIAlertController *alert =
            [UIAlertController
                alertControllerWithTitle:@"BLE Logs"
                message:text
                preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:
            [UIAlertAction
                actionWithTitle:@"复制全部"
                style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {

                    [self copyLogs];
                }]];

        [alert addAction:
            [UIAlertAction
                actionWithTitle:@"关闭"
                style:UIAlertActionStyleCancel
                handler:nil]];

        [root presentViewController:alert
                           animated:YES
                         completion:nil];
    });
}

+ (void)clearLogs {

    YCYClearLogs();

    YCYToast(@"BLE 日志已清空");
}

+ (void)copyLogs {

    NSString *text =
        YCYSnapshotLogs();

    UIPasteboard.generalPasteboard.string =
        text ?: @"";

    YCYToast(@"完整 BLE 日志已复制");
}

+ (void)onPan:(UIPanGestureRecognizer *)pan {

    if (!floatWindow) {
        return;
    }

    CGPoint translation =
        [pan translationInView:floatWindow];

    CGPoint center =
        floatWindow.center;

    center.x += translation.x;
    center.y += translation.y;

    floatWindow.center = center;

    [pan setTranslation:CGPointZero
               inView:floatWindow];
}

@end

#pragma mark - CBPeripheral Monitoring

%hook CBPeripheral

- (void)setDelegate:(id<CBPeripheralDelegate>)delegate {

    if (monitorEnabled) {

        YCYLog(@"========== BLE DELEGATE ==========");

        YCYLog(@"Peripheral: %@",
               YCYPeripheralName(self));

        YCYLog(@"Peripheral UUID: %@",
               self.identifier.UUIDString ?: @"<nil>");

        YCYLog(@"Delegate Class: %@",
               delegate
                   ? NSStringFromClass([delegate class])
                   : @"<nil>");
    }

    %orig;
}

- (void)discoverServices:(NSArray<CBUUID *> *)serviceUUIDs {

    if (monitorEnabled) {

        NSMutableArray *uuids =
            [NSMutableArray array];

        for (CBUUID *uuid in serviceUUIDs) {

            if (uuid.UUIDString) {
                [uuids addObject:
                    uuid.UUIDString];
            }
        }

        YCYLog(@"========== BLE DISCOVER SERVICES ==========");

        YCYLog(@"Peripheral: %@",
               YCYPeripheralName(self));

        YCYLog(@"Peripheral UUID: %@",
               self.identifier.UUIDString ?: @"<nil>");

        YCYLog(@"Services: %@",
               uuids.count
                   ? [uuids componentsJoinedByString:@", "]
                   : @"ALL");
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

            if (uuid.UUIDString) {
                [uuids addObject:
                    uuid.UUIDString];
            }
        }

        YCYLog(
            @"========== BLE DISCOVER CHARACTERISTICS =========="
        );

        YCYLog(@"Peripheral: %@",
               YCYPeripheralName(self));

        YCYLog(@"Service: %@",
               service.UUID.UUIDString ?: @"<nil>");

        YCYLog(@"Characteristics: %@",
               uuids.count
                   ? [uuids componentsJoinedByString:@", "]
                   : @"ALL");
    }

    %orig;
}

- (void)readValueForCharacteristic:
    (CBCharacteristic *)characteristic {

    if (monitorEnabled) {

        YCYLog(@"========== BLE READ ==========");

        YCYLog(@"Peripheral: %@",
               YCYPeripheralName(self));

        YCYLog(@"Peripheral UUID: %@",
               self.identifier.UUIDString ?: @"<nil>");

        YCYLog(@"Service: %@",
               characteristic.service.UUID.UUIDString
                   ?: @"<nil>");

        YCYLog(@"Characteristic: %@",
               characteristic.UUID.UUIDString
                   ?: @"<nil>");
    }

    %orig;
}

- (void)setNotifyValue:(BOOL)enabled
     forCharacteristic:(CBCharacteristic *)characteristic {

    if (monitorEnabled) {

        YCYLog(@"========== BLE NOTIFY %@ ==========",
               enabled ? @"ENABLE" : @"DISABLE");

        YCYLog(@"Peripheral: %@",
               YCYPeripheralName(self));

        YCYLog(@"Peripheral UUID: %@",
               self.identifier.UUIDString ?: @"<nil>");

        YCYLog(@"Service: %@",
               characteristic.service.UUID.UUIDString
                   ?: @"<nil>");

        YCYLog(@"Characteristic: %@",
               characteristic.UUID.UUIDString
                   ?: @"<nil>");
    }

    %orig;
}

- (void)writeValue:(NSData *)data
 forCharacteristic:(CBCharacteristic *)characteristic
              type:(CBCharacteristicWriteType)type {

    if (monitorEnabled) {

        YCYLog(@"========== BLE WRITE ==========");

        YCYLog(@"Peripheral: %@",
               YCYPeripheralName(self));

        YCYLog(@"Peripheral UUID: %@",
               self.identifier.UUIDString ?: @"<nil>");

        YCYLog(@"Service: %@",
               characteristic.service.UUID.UUIDString
                   ?: @"<nil>");

        YCYLog(@"Characteristic: %@",
               characteristic.UUID.UUIDString
                   ?: @"<nil>");

        YCYLog(@"Properties: %@",
               YCYCharacteristicProperties(
                   characteristic.properties));

        YCYLog(@"Length: %lu",
               (unsigned long)data.length);

        YCYLog(@"Write Type: %ld",
               (long)type);

        YCYLog(@"HEX: %@",
               YCYHexString(data));
    }

    %orig;
}

%end

#pragma mark - CBCentralManager Monitoring

%hook CBCentralManager

- (void)scanForPeripheralsWithServices:
            (NSArray<CBUUID *> *)serviceUUIDs
                              options:
            (NSDictionary<NSString *, id> *)options {

    if (monitorEnabled) {

        NSMutableArray *uuids =
            [NSMutableArray array];

        for (CBUUID *uuid in serviceUUIDs) {

            if (uuid.UUIDString) {
                [uuids addObject:
                    uuid.UUIDString];
            }
        }

        YCYLog(@"========== BLE SCAN ==========");

        YCYLog(@"Services: %@",
               uuids.count
                   ? [uuids componentsJoinedByString:@", "]
                   : @"ALL");

        YCYLog(@"Options: %@",
               options ?: @{});
    }

    %orig;
}

- (void)stopScan {

    if (monitorEnabled) {

        YCYLog(@"========== BLE STOP SCAN ==========");
    }

    %orig;
}

- (void)connectPeripheral:(CBPeripheral *)peripheral
                   options:(NSDictionary<NSString *, id> *)options {

    if (monitorEnabled) {

        YCYLog(@"========== BLE CONNECT ==========");

        YCYLog(@"Peripheral: %@",
               YCYPeripheralName(peripheral));

        YCYLog(@"Peripheral UUID: %@",
               peripheral.identifier.UUIDString
                   ?: @"<nil>");

        YCYLog(@"Options: %@",
               options ?: @{});
    }

    %orig;
}

- (void)cancelPeripheralConnection:
    (CBPeripheral *)peripheral {

    if (monitorEnabled) {

        YCYLog(@"========== BLE DISCONNECT REQUEST ==========");

        YCYLog(@"Peripheral: %@",
               YCYPeripheralName(peripheral));

        YCYLog(@"Peripheral UUID: %@",
               peripheral.identifier.UUIDString
                   ?: @"<nil>");
    }

    %orig;
}

%end

#pragma mark - UIApplication Startup

%hook UIApplication

- (void)applicationDidBecomeActive:(UIApplication *)application {

    %orig;

    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{

        YCYInitLogger();

        YCYLog(@"================================");
        YCYLog(@"YCYUnlock BLE Monitor Loaded");
        YCYLog(@"================================");

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(3 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{

                YCYCreateFloatButton();
            });
    });
}

%end

#pragma mark - Constructor

%ctor {

    YCYInitLogger();

    YCYLog(@"YCYUnlock Tweak Constructor");
}

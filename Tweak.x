#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#pragma mark - 常量（YS04）

static NSString * const kYCYChar9001 = @"00009001-0000-1000-8000-57616C6B697A";
static NSString * const kYCYCharAE01 = @"AE01";
static NSString * const kYCYSvc9000  = @"00009000-0000-1000-8000-57616C6B697A";
static NSString * const kYCYSvcAE00  = @"AE00";

#pragma mark - 全局

static UIWindow *floatWindow;
static UIButton *floatButton;
static UILabel  *toastLabel;

static NSMutableArray<NSString *> *bleLogs;
static NSLock *bleLogLock;

static BOOL monitorEnabled = YES;
static BOOL recordingEnabled = YES;

static NSMutableSet<CBPeripheral *> *knownPeripherals;
static NSLock *peripheralLock;

@interface YCYRecordedWrite : NSObject
@property (nonatomic, copy) NSUUID *peripheralID;
@property (nonatomic, copy) NSString *peripheralName;
@property (nonatomic, copy) NSString *serviceUUID;
@property (nonatomic, copy) NSString *charUUID;
@property (nonatomic, copy) NSData *value;
@property (nonatomic, assign) CBCharacteristicWriteType type;
@property (nonatomic, strong) NSDate *time;
@end

@implementation YCYRecordedWrite
@end

static NSMutableArray<YCYRecordedWrite *> *recordedWrites;
static NSLock *recordLock;

#pragma mark - 工具

static void YCYInitState(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bleLogs = [NSMutableArray array];
        bleLogLock = [[NSLock alloc] init];
        recordedWrites = [NSMutableArray array];
        recordLock = [[NSLock alloc] init];
        knownPeripherals = [NSMutableSet set];
        peripheralLock = [[NSLock alloc] init];
        NSLog(@"[YCYUnlock] State initialized");
    });
}

static void YCYLog(NSString *format, ...) {
    YCYInitState();
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"[YCYUnlock] %@", message];
    NSLog(@"%@", line);

    [bleLogLock lock];
    [bleLogs addObject:line];
    if (bleLogs.count > 500) {
        [bleLogs removeObjectsInRange:NSMakeRange(0, bleLogs.count - 500)];
    }
    [bleLogLock unlock];
}

static NSString *YCYHexString(NSData *data) {
    if (!data || data.length == 0) return @"<empty>";
    const unsigned char *bytes = data.bytes;
    NSMutableString *result = [NSMutableString string];
    for (NSUInteger i = 0; i < data.length; i++) {
        [result appendFormat:@"%02X", bytes[i]];
        if (i + 1 < data.length) [result appendString:@" "];
    }
    return result;
}

static NSData *YCYDataFromHex(NSString *hex) {
    NSString *clean = [[hex uppercaseString]
        stringByReplacingOccurrencesOfString:@" " withString:@""];
    if (clean.length < 2 || (clean.length % 2) != 0) return nil;
    NSMutableData *data = [NSMutableData dataWithCapacity:clean.length / 2];
    for (NSUInteger i = 0; i + 1 < clean.length; i += 2) {
        unsigned int byte = 0;
        NSScanner *scanner = [NSScanner scannerWithString:
            [clean substringWithRange:NSMakeRange(i, 2)]];
        if (![scanner scanHexInt:&byte]) return nil;
        uint8_t b = (uint8_t)byte;
        [data appendBytes:&b length:1];
    }
    return data;
}

static NSString *YCYUUIDString(NSUUID *uuid) {
    return uuid.UUIDString ?: @"<nil>";
}

static NSString *YCYPeripheralName(CBPeripheral *peripheral) {
    if (!peripheral) return @"<nil>";
    return peripheral.name.length ? peripheral.name : @"<Unnamed>";
}

static NSString *YCYNormUUID(id uuidObj) {
    NSString *s = nil;
    if ([uuidObj isKindOfClass:[CBUUID class]]) {
        s = [(CBUUID *)uuidObj UUIDString];
    } else if ([uuidObj isKindOfClass:[NSString class]]) {
        s = (NSString *)uuidObj;
    } else if ([uuidObj isKindOfClass:[NSUUID class]]) {
        s = [(NSUUID *)uuidObj UUIDString];
    }
    return s.uppercaseString ?: @"";
}

static BOOL YCYUUIDMatch(NSString *a, NSString *b) {
    NSString *x = YCYNormUUID(a);
    NSString *y = YCYNormUUID(b);
    if (x.length == 0 || y.length == 0) return NO;
    if ([x isEqualToString:y]) return YES;
    // 16-bit 短 UUID 对比（AE01 vs 0000AE01-0000-1000-8000-00805F9B34FB）
    NSString *shortX = x;
    NSString *shortY = y;
    if (x.length == 36 && [x hasPrefix:@"0000"] && [x hasSuffix:@"-0000-1000-8000-00805F9B34FB"]) {
        shortX = [x substringWithRange:NSMakeRange(4, 4)];
    }
    if (y.length == 36 && [y hasPrefix:@"0000"] && [y hasSuffix:@"-0000-1000-8000-00805F9B34FB"]) {
        shortY = [y substringWithRange:NSMakeRange(4, 4)];
    }
    if (x.length == 4) shortX = x;
    if (y.length == 4) shortY = y;
    return [shortX isEqualToString:shortY];
}

static BOOL YCYIsTargetCharacteristic(NSString *uuid) {
    NSString *u = YCYNormUUID(uuid);
    if (u.length == 0) return NO;
    if (YCYUUIDMatch(u, kYCYChar9001)) return YES;
    if (YCYUUIDMatch(u, kYCYCharAE01)) return YES;
    if ([u containsString:@"9001"]) return YES;
    if ([u containsString:@"AE01"]) return YES;
    return NO;
}

static BOOL YCYLooksLikeUnlockPayload(NSData *data) {
    if (!data || data.length < 2) return NO;
    const unsigned char *b = data.bytes;
    // YS0x: 01 00  (token) / 20 01 ... (open)
    if (data.length >= 2 && b[0] == 0x01 && b[1] == 0x00) return YES;
    if (data.length >= 2 && b[0] == 0x20 && b[1] == 0x01) return YES;
    if (data.length >= 3 && b[0] == 0x05 && b[1] == 0x01 && b[2] == 0x06) return YES;
    if (data.length >= 4 && b[0] == 0x06 && b[1] == 0x01 && b[2] == 0x01 && b[3] == 0x01) return YES;
    if (data.length >= 4 && b[0] == 0xAF && b[1] == 0x0F && (b[2] == 0xC0 || b[2] == 0xD0)) return YES;
    return NO;
}

static NSString *YCYProperties(CBCharacteristic *characteristic) {
    CBCharacteristicProperties p = characteristic.properties;
    NSMutableArray *items = [NSMutableArray array];
    if (p & CBCharacteristicPropertyBroadcast) [items addObject:@"Broadcast"];
    if (p & CBCharacteristicPropertyRead) [items addObject:@"Read"];
    if (p & CBCharacteristicPropertyWriteWithoutResponse) [items addObject:@"WriteWithoutResponse"];
    if (p & CBCharacteristicPropertyWrite) [items addObject:@"Write"];
    if (p & CBCharacteristicPropertyNotify) [items addObject:@"Notify"];
    if (p & CBCharacteristicPropertyIndicate) [items addObject:@"Indicate"];
    return items.count ? [items componentsJoinedByString:@" | "] : @"None";
}

static void YCYRememberPeripheral(CBPeripheral *peripheral) {
    if (!peripheral) return;
    [peripheralLock lock];
    [knownPeripherals addObject:peripheral];
    [peripheralLock unlock];
}

static NSArray<CBPeripheral *> *YCYConnectedPeripherals(void) {
    [peripheralLock lock];
    NSArray *all = [knownPeripherals allObjects];
    [peripheralLock unlock];
    NSMutableArray *connected = [NSMutableArray array];
    for (CBPeripheral *p in all) {
        if (p.state == CBPeripheralStateConnected) {
            [connected addObject:p];
        }
    }
    return connected;
}

static CBCharacteristic *YCYFindCharacteristic(CBPeripheral *peripheral, NSString *serviceUUID, NSString *charUUID) {
    if (!peripheral.services) return nil;
    for (CBService *service in peripheral.services) {
        if (serviceUUID.length && !YCYUUIDMatch(service.UUID.UUIDString, serviceUUID)) {
            // 允许只按特征 UUID 匹配
        }
        for (CBCharacteristic *c in service.characteristics) {
            if (YCYUUIDMatch(c.UUID.UUIDString, charUUID)) {
                return c;
            }
        }
    }
    return nil;
}

static NSArray<CBCharacteristic *> *YCYWriteCharacteristics(CBPeripheral *peripheral) {
    NSMutableArray *result = [NSMutableArray array];
    for (CBService *service in peripheral.services) {
        for (CBCharacteristic *c in service.characteristics) {
            CBCharacteristicProperties p = c.properties;
            BOOL canWrite = (p & CBCharacteristicPropertyWriteWithoutResponse) ||
                            (p & CBCharacteristicPropertyWrite);
            if (canWrite) [result addObject:c];
        }
    }
    return result;
}

#pragma mark - Toast / 弹窗

static UIWindow *YCYHostWindow(void) {
    if (floatWindow && !floatWindow.hidden) return floatWindow;

    UIApplication *application = [UIApplication sharedApplication];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow && !window.hidden) return window;
            }
            for (UIWindow *window in windowScene.windows) {
                if (!window.hidden) return window;
            }
        }
    }
    return nil;
}

static UIViewController *YCYTopVC(void) {
    UIWindow *window = YCYHostWindow();
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void YCYShowToast(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = YCYHostWindow();
        if (!window) {
            YCYLog(@"Toast skipped, no window: %@", text);
            return;
        }
        if (!toastLabel) {
            toastLabel = [[UILabel alloc] init];
            toastLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
            toastLabel.textColor = [UIColor whiteColor];
            toastLabel.font = [UIFont systemFontOfSize:13];
            toastLabel.textAlignment = NSTextAlignmentCenter;
            toastLabel.numberOfLines = 0;
            toastLabel.layer.cornerRadius = 10;
            toastLabel.layer.masksToBounds = YES;
        }
        toastLabel.text = [NSString stringWithFormat:@"  %@  ", text];
        [toastLabel sizeToFit];
        CGFloat w = MIN(window.bounds.size.width - 40, MAX(180, toastLabel.bounds.size.width + 24));
        CGFloat h = MAX(36, toastLabel.bounds.size.height + 16);
        toastLabel.frame = CGRectMake((window.bounds.size.width - w) / 2.0,
                                      window.bounds.size.height - 140, w, h);
        toastLabel.alpha = 0;
        [window addSubview:toastLabel];
        [UIView animateWithDuration:0.2 animations:^{ toastLabel.alpha = 1; }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.25 animations:^{
                toastLabel.alpha = 0;
            } completion:^(BOOL finished) {
                [toastLabel removeFromSuperview];
            }];
        });
    });
}

#pragma mark - 记录 / 重放

static void YCYRecordWrite(CBPeripheral *peripheral,
                           CBCharacteristic *characteristic,
                           NSData *data,
                           CBCharacteristicWriteType type) {
    if (!recordingEnabled || !peripheral || !characteristic || !data) return;

    NSString *charUUID = characteristic.UUID.UUIDString ?: @"";
    BOOL target = YCYIsTargetCharacteristic(charUUID) || YCYLooksLikeUnlockPayload(data);
    if (!target) return;

    YCYRecordedWrite *item = [YCYRecordedWrite new];
    item.peripheralID = peripheral.identifier;
    item.peripheralName = YCYPeripheralName(peripheral);
    item.serviceUUID = characteristic.service.UUID.UUIDString ?: @"";
    item.charUUID = charUUID;
    item.value = [data copy];
    item.type = type;
    item.time = [NSDate date];

    [recordLock lock];
    [recordedWrites addObject:item];
    if (recordedWrites.count > 40) {
        [recordedWrites removeObjectsInRange:NSMakeRange(0, recordedWrites.count - 40)];
    }
    [recordLock unlock];

    YCYLog(@"★ 已记录开锁相关写入 name=%@ char=%@ len=%lu HEX=%@",
           item.peripheralName, item.charUUID,
           (unsigned long)data.length, YCYHexString(data));
}

static NSArray<YCYRecordedWrite *> *YCYLatestBurst(void) {
    [recordLock lock];
    NSArray *all = [recordedWrites copy];
    [recordLock unlock];
    if (all.count == 0) return @[];

    YCYRecordedWrite *last = all.lastObject;
    NSMutableArray *burst = [NSMutableArray array];
    // 取最后一次写入前后 4 秒内的目标包，保持顺序
    for (YCYRecordedWrite *item in all) {
        if (fabs([item.time timeIntervalSinceDate:last.time]) <= 4.0) {
            [burst addObject:item];
        }
    }
    if (burst.count == 0) [burst addObject:last];
    return burst;
}

static BOOL YCYWriteData(CBPeripheral *peripheral,
                         CBCharacteristic *characteristic,
                         NSData *data) {
    if (!peripheral || !characteristic || !data) return NO;
    if (peripheral.state != CBPeripheralStateConnected) return NO;

    CBCharacteristicWriteType type =
        (characteristic.properties & CBCharacteristicPropertyWriteWithoutResponse)
            ? CBCharacteristicWriteWithoutResponse
            : CBCharacteristicWriteWithResponse;

    @try {
        [peripheral writeValue:data forCharacteristic:characteristic type:type];
        YCYLog(@"已写入 name=%@ char=%@ len=%lu HEX=%@",
               YCYPeripheralName(peripheral),
               characteristic.UUID.UUIDString,
               (unsigned long)data.length,
               YCYHexString(data));
        return YES;
    } @catch (NSException *ex) {
        YCYLog(@"写入异常: %@", ex.reason);
        return NO;
    }
}

static NSInteger YCYReplayBurst(NSArray<YCYRecordedWrite *> *burst) {
    NSArray *connected = YCYConnectedPeripherals();

    void (^sendOne)(YCYRecordedWrite *) = ^(YCYRecordedWrite *item) {
        CBPeripheral *target = nil;
        for (CBPeripheral *p in connected) {
            if ([p.identifier isEqual:item.peripheralID]) {
                target = p;
                break;
            }
        }
        if (!target && connected.count == 1) target = connected.firstObject;
        if (!target) {
            for (CBPeripheral *p in connected) {
                NSString *name = YCYPeripheralName(p).uppercaseString;
                if ([name containsString:@"YS"]) {
                    target = p;
                    break;
                }
            }
        }
        if (!target) target = connected.firstObject;
        if (!target) return;

        CBCharacteristic *ch = YCYFindCharacteristic(target, item.serviceUUID, item.charUUID);
        if (!ch) {
            for (CBCharacteristic *c in YCYWriteCharacteristics(target)) {
                if (YCYIsTargetCharacteristic(c.UUID.UUIDString)) {
                    ch = c;
                    break;
                }
            }
        }
        if (!ch) ch = YCYWriteCharacteristics(target).firstObject;
        if (ch) {
            YCYWriteData(target, ch, item.value);
        }
    };

    for (NSUInteger i = 0; i < burst.count; i++) {
        YCYRecordedWrite *item = burst[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.12 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            sendOne(item);
        });
    }
    return (NSInteger)burst.count;
}

static NSInteger YCYSendCandidates(void) {
    NSArray *connected = YCYConnectedPeripherals();
    if (connected.count == 0) return 0;

    NSArray *hexes = @[
        @"0100",
        @"2001",
        @"2001FFFFFFFF",
        @"06010101",
        @"AF0FD001",
        @"AF0FC001",
        @"050106"
    ];

    NSInteger sent = 0;
    NSInteger delayIndex = 0;
    for (CBPeripheral *p in connected) {
        NSArray *chars = YCYWriteCharacteristics(p);
        NSMutableArray *targets = [NSMutableArray array];
        for (CBCharacteristic *c in chars) {
            if (YCYIsTargetCharacteristic(c.UUID.UUIDString)) {
                [targets addObject:c];
            }
        }
        if (targets.count == 0) [targets addObjectsFromArray:chars];

        for (CBCharacteristic *c in targets) {
            for (NSString *hex in hexes) {
                NSData *data = YCYDataFromHex(hex);
                if (!data) continue;
                NSInteger capture = delayIndex++;
                CBPeripheral *pp = p;
                CBCharacteristic *cc = c;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(capture * 0.08 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    YCYWriteData(pp, cc, data);
                });
                sent++;
            }
        }
    }
    return sent;
}

static void YCYTryUnlock(void) {
    YCYInitState();
    NSArray *connected = YCYConnectedPeripherals();
    NSArray *burst = YCYLatestBurst();

    YCYLog(@"尝试开锁 connected=%lu recordedBurst=%lu",
           (unsigned long)connected.count,
           (unsigned long)burst.count);

    if (connected.count == 0) {
        YCYShowToast(@"未发现已连接的锁盒\n请先在 App 内连上 YS04");
        return;
    }

    if (burst.count > 0) {
        NSInteger n = YCYReplayBurst(burst);
        YCYShowToast([NSString stringWithFormat:@"正在重放 %ld 条已记录指令", (long)n]);
        return;
    }

    NSInteger n = YCYSendCandidates();
    if (n > 0) {
        YCYShowToast(@"没有记录到真实开锁包\n已发送候选指令，建议先正常开锁一次");
    } else {
        YCYShowToast(@"已连接，但找不到可写特征\n请先在 App 内打开锁页完成一次发现");
    }
}

#pragma mark - 日志 UI

static void YCYShowLogs(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [bleLogLock lock];
        NSString *text = bleLogs.count
            ? [bleLogs componentsJoinedByString:@"\n"]
            : @"暂无 BLE 日志";
        [bleLogLock unlock];

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"YCY BLE 日志"
                                                message:text
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"关闭"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [YCYTopVC() presentViewController:alert animated:YES completion:nil];
    });
}

static void YCYShowRecords(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [recordLock lock];
        NSArray *all = [recordedWrites copy];
        [recordLock unlock];

        NSMutableString *text = [NSMutableString string];
        if (all.count == 0) {
            [text appendString:@"暂无已记录的开锁指令\n请先让控方正常同意并成功开锁一次"];
        } else {
            NSInteger i = 1;
            for (YCYRecordedWrite *item in all) {
                [text appendFormat:@"%ld. %@ char=%@ len=%lu\n%@\n\n",
                 (long)i++,
                 item.peripheralName,
                 item.charUUID,
                 (unsigned long)item.value.length,
                 YCYHexString(item.value)];
            }
        }

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"已记录指令"
                                                message:text
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"关闭"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [YCYTopVC() presentViewController:alert animated:YES completion:nil];
    });
}

static void YCYCopyLogs(void) {
    [bleLogLock lock];
    UIPasteboard.generalPasteboard.string = [bleLogs componentsJoinedByString:@"\n"];
    [bleLogLock unlock];
    YCYShowToast(@"日志已复制");
}

static void YCYClearLogs(void) {
    [bleLogLock lock];
    [bleLogs removeAllObjects];
    [bleLogLock unlock];
    YCYLog(@"Logs cleared");
    YCYShowToast(@"日志已清空");
}

static void YCYClearRecords(void) {
    [recordLock lock];
    [recordedWrites removeAllObjects];
    [recordLock unlock];
    YCYLog(@"Records cleared");
    YCYShowToast(@"已清空记录的开锁指令");
}

#pragma mark - 悬浮窗

@interface YCYOverlayWindow : UIWindow
@end

@implementation YCYOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || hitView == self.rootViewController.view) return nil;
    return hitView;
}
@end

@interface YCYUnlockHelper : NSObject
+ (instancetype)shared;
- (void)onTap;
- (void)onLongPress:(UILongPressGestureRecognizer *)g;
- (void)onPan:(UIPanGestureRecognizer *)g;
@end

static void YCYShowMenu(UIButton *sender) {
    NSString *msg = [NSString stringWithFormat:
        @"短按：立即开锁（重放已记录指令）\n长按：打开本菜单\n监控：%@   已记录：%lu 条\n已连接设备：%lu",
        monitorEnabled ? @"开" : @"关",
        (unsigned long)recordedWrites.count,
        (unsigned long)YCYConnectedPeripherals().count];

    UIAlertController *menu =
        [UIAlertController alertControllerWithTitle:@"YCY Unlock"
                                            message:msg
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    [menu addAction:[UIAlertAction actionWithTitle:@"立即开锁"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *a) { YCYTryUnlock(); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"查看已记录指令"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { YCYShowRecords(); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"查看 BLE 日志"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { YCYShowLogs(); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"复制 BLE 日志"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { YCYCopyLogs(); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"清空日志"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { YCYClearLogs(); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"清空开锁记录"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { YCYClearRecords(); }]];
    [menu addAction:[UIAlertAction
        actionWithTitle:monitorEnabled ? @"关闭监控" : @"开启监控"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *a) {
                    monitorEnabled = !monitorEnabled;
                    YCYLog(@"Monitor %@", monitorEnabled ? @"enabled" : @"disabled");
                    YCYShowToast(monitorEnabled ? @"监控已开启" : @"监控已关闭");
                }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    if (menu.popoverPresentationController) {
        menu.popoverPresentationController.sourceView = sender ?: floatButton;
        menu.popoverPresentationController.sourceRect = sender.bounds;
    }
    [YCYTopVC() presentViewController:menu animated:YES completion:nil];
}

@implementation YCYUnlockHelper

+ (instancetype)shared {
    static YCYUnlockHelper *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [YCYUnlockHelper new]; });
    return inst;
}

- (void)onTap {
    YCYTryUnlock();
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        YCYShowMenu(floatButton);
    }
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *v = floatButton;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];

    CGRect b = v.superview.bounds;
    CGRect f = v.frame;
    if (CGRectGetMinX(f) < 0) f.origin.x = 0;
    if (CGRectGetMinY(f) < 80) f.origin.y = 80;
    if (CGRectGetMaxX(f) > b.size.width) f.origin.x = b.size.width - f.size.width;
    if (CGRectGetMaxY(f) > b.size.height - 40) f.origin.y = b.size.height - f.size.height - 40;
    v.frame = f;
}

@end

static void YCYCreateFloatingButton(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (floatWindow) {
            floatWindow.hidden = NO;
            if (floatButton) floatButton.hidden = NO;
            return;
        }

        UIScreen *screen = [UIScreen mainScreen];
        floatWindow = [[YCYOverlayWindow alloc] initWithFrame:screen.bounds];
        floatWindow.windowLevel = UIWindowLevelAlert + 100;
        floatWindow.backgroundColor = [UIColor clearColor];
        floatWindow.opaque = NO;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]] &&
                    scene.activationState == UISceneActivationStateForegroundActive) {
                    floatWindow.windowScene = (UIWindowScene *)scene;
                    break;
                }
            }
        }

        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = [UIColor clearColor];

        floatButton = [UIButton buttonWithType:UIButtonTypeCustom];
        floatButton.frame = CGRectMake(screen.bounds.size.width - 86, 180, 70, 70);
        floatButton.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.92];
        [floatButton setTitle:@"开锁" forState:UIControlStateNormal];
        [floatButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        floatButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        floatButton.layer.cornerRadius = 35;
        floatButton.layer.masksToBounds = NO;
        floatButton.layer.shadowOpacity = 0.35;
        floatButton.layer.shadowRadius = 6;
        floatButton.layer.shadowOffset = CGSizeMake(0, 3);

        [floatButton addTarget:[YCYUnlockHelper shared]
                        action:@selector(onTap)
              forControlEvents:UIControlEventTouchUpInside];

        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:[YCYUnlockHelper shared]
                                                    action:@selector(onPan:)];
        [floatButton addGestureRecognizer:pan];

        UILongPressGestureRecognizer *lp =
            [[UILongPressGestureRecognizer alloc] initWithTarget:[YCYUnlockHelper shared]
                                                          action:@selector(onLongPress:)];
        lp.minimumPressDuration = 0.45;
        [floatButton addGestureRecognizer:lp];

        [vc.view addSubview:floatButton];
        floatWindow.rootViewController = vc;
        floatWindow.hidden = NO;
        YCYLog(@"Floating unlock button created");
    });
}

static void YCYScheduleFloatingButton(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YCYCreateFloatingButton();
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YCYCreateFloatingButton();
    });
}

#pragma mark - CoreBluetooth Monitor + 记录

%hook CBCentralManager

- (void)scanForPeripheralsWithServices:(NSArray<CBUUID *> *)serviceUUIDs
                               options:(NSDictionary<NSString *,id> *)options {
    if (monitorEnabled) {
        NSMutableArray *uuids = [NSMutableArray array];
        for (CBUUID *uuid in serviceUUIDs) [uuids addObject:uuid.UUIDString];
        YCYLog(@"scan services=%@ options=%@", uuids, options);
    }
    %orig;
}

- (void)stopScan {
    if (monitorEnabled) YCYLog(@"stopScan");
    %orig;
}

- (void)connectPeripheral:(CBPeripheral *)peripheral
                  options:(NSDictionary<NSString *,id> *)options {
    YCYRememberPeripheral(peripheral);
    if (monitorEnabled) {
        YCYLog(@"connect name=%@ UUID=%@",
               YCYPeripheralName(peripheral),
               YCYUUIDString(peripheral.identifier));
    }
    %orig;
}

- (void)cancelPeripheralConnection:(CBPeripheral *)peripheral {
    if (monitorEnabled) {
        YCYLog(@"cancelConnect name=%@ UUID=%@",
               YCYPeripheralName(peripheral),
               YCYUUIDString(peripheral.identifier));
    }
    %orig;
}

- (NSArray<CBPeripheral *> *)retrieveConnectedPeripheralsWithServices:(NSArray<CBUUID *> *)serviceUUIDs {
    NSArray *result = %orig;
    for (CBPeripheral *p in result) YCYRememberPeripheral(p);
    return result;
}

%end

%hook CBPeripheral

- (void)setDelegate:(id<CBPeripheralDelegate>)delegate {
    YCYRememberPeripheral(self);
    if (monitorEnabled) {
        YCYLog(@"%@ setDelegate class=%@",
               YCYPeripheralName(self),
               delegate ? NSStringFromClass([delegate class]) : @"<nil>");
    }
    %orig;
}

- (void)discoverServices:(NSArray<CBUUID *> *)serviceUUIDs {
    YCYRememberPeripheral(self);
    if (monitorEnabled) {
        NSMutableArray *uuids = [NSMutableArray array];
        for (CBUUID *uuid in serviceUUIDs) [uuids addObject:uuid.UUIDString];
        YCYLog(@"%@ discoverServices=%@", YCYPeripheralName(self), uuids);
    }
    %orig;
}

- (void)discoverCharacteristics:(NSArray<CBUUID *> *)characteristicUUIDs
                     forService:(CBService *)service {
    if (monitorEnabled) {
        NSMutableArray *uuids = [NSMutableArray array];
        for (CBUUID *uuid in characteristicUUIDs) [uuids addObject:uuid.UUIDString];
        YCYLog(@"%@ discoverCharacteristics service=%@ chars=%@",
               YCYPeripheralName(self),
               service.UUID.UUIDString,
               uuids);
    }
    %orig;
}

- (void)readValueForCharacteristic:(CBCharacteristic *)characteristic {
    if (monitorEnabled) {
        YCYLog(@"%@ READ service=%@ char=%@",
               YCYPeripheralName(self),
               characteristic.service.UUID.UUIDString,
               characteristic.UUID.UUIDString);
    }
    %orig;
}

- (void)setNotifyValue:(BOOL)enabled forCharacteristic:(CBCharacteristic *)characteristic {
    if (monitorEnabled) {
        YCYLog(@"%@ NOTIFY %@ service=%@ char=%@",
               YCYPeripheralName(self),
               enabled ? @"ON" : @"OFF",
               characteristic.service.UUID.UUIDString,
               characteristic.UUID.UUIDString);
    }
    %orig;
}

- (void)writeValue:(NSData *)data
 forCharacteristic:(CBCharacteristic *)characteristic
              type:(CBCharacteristicWriteType)type {
    YCYRememberPeripheral(self);

    if (monitorEnabled) {
        NSString *writeType = (type == CBCharacteristicWriteWithResponse)
            ? @"WithResponse" : @"WithoutResponse";
        YCYLog(@"%@ WRITE service=%@ char=%@ props=[%@] type=%@ len=%lu HEX=%@",
               YCYPeripheralName(self),
               characteristic.service.UUID.UUIDString,
               characteristic.UUID.UUIDString,
               YCYProperties(characteristic),
               writeType,
               (unsigned long)data.length,
               YCYHexString(data));
    }

    YCYRecordWrite(self, characteristic, data, type);
    %orig;
}

%end

#pragma mark - App 生命周期

%hook UIApplication

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    YCYInitState();
    YCYLog(@"didFinishLaunching");
    BOOL result = %orig(application, launchOptions);
    YCYScheduleFloatingButton();
    return result;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    YCYInitState();
    YCYLog(@"applicationDidBecomeActive");
    %orig;
    YCYScheduleFloatingButton();
}

%end

%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;
    YCYScheduleFloatingButton();
}

%end

%ctor {
    YCYInitState();
    YCYLog(@"==============================");
    YCYLog(@"YCYUnlock loaded");
    YCYLog(@"短按悬浮窗 = 开锁重放");
    YCYLog(@"长按悬浮窗 = 菜单 / 日志");
    YCYLog(@"==============================");
    YCYScheduleFloatingButton();
}

#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#pragma mark - 常量（YS04）

static NSString * const kYCYChar9001 = @"00009001-0000-1000-8000-57616C6B697A";
static NSString * const kYCYCharAE01 = @"AE01";
static NSString * const kYCYSvc9000  = @"00009000-0000-1000-8000-57616C6B697A";
static NSString * const kYCYSvcAE00  = @"AE00";
static NSString * const kYCYRecordsKey = @"YCYUnlock.canonicalWrites.v2";
static NSString * const kYCYLockUUIDKey = @"YCYUnlock.lastLockUUID";
static NSString * const kYCYLockNameKey = @"YCYUnlock.lastLockName";

#pragma mark - 全局

static UIWindow *floatWindow;
static UIButton *floatButton;
static UILabel  *toastLabel;

static NSMutableArray<NSString *> *bleLogs;
static NSLock *bleLogLock;

static BOOL monitorEnabled = YES;
static BOOL gIgnoreHookWrite = NO;
static BOOL gUnlockInFlight = NO;
static BOOL gCanonicalFrozen = NO;
static BOOL gNeedsRediscover = NO;
static NSDate *gHandshakeUntil;

static NSMutableDictionary<NSString *, CBPeripheral *> *peripheralsByUUID;
static NSLock *peripheralLock;
static CBCentralManager *appCentral;
static NSUUID *lastLockUUID;
static NSString *lastLockName;
static __weak CBPeripheral *lastAppPeripheral;
static NSDate *lastAppWriteTime;
static NSMutableSet<NSString *> *observedPeripheralIDs;

@interface YCYRecordedWrite : NSObject
@property (nonatomic, copy) NSUUID *peripheralID;
@property (nonatomic, copy) NSString *peripheralName;
@property (nonatomic, copy) NSString *serviceUUID;
@property (nonatomic, copy) NSString *charUUID;
@property (nonatomic, copy) NSData *value;
@property (nonatomic, assign) CBCharacteristicWriteType type;
@property (nonatomic, strong) NSDate *time;
@property (nonatomic, assign) BOOL unlockLike;
@end

@implementation YCYRecordedWrite
@end

static NSMutableArray<YCYRecordedWrite *> *canonicalWrites;
static NSMutableArray<YCYRecordedWrite *> *liveSession;
static NSLock *recordLock;
static dispatch_block_t gFreezeBlock;

#pragma mark - 工具

static void YCYPersistRecords(void);
static void YCYLoadRecords(void);
static void YCYScheduleFloatingButton(void);

static void YCYInitState(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bleLogs = [NSMutableArray array];
        bleLogLock = [[NSLock alloc] init];
        canonicalWrites = [NSMutableArray array];
        liveSession = [NSMutableArray array];
        recordLock = [[NSLock alloc] init];
        peripheralsByUUID = [NSMutableDictionary dictionary];
        peripheralLock = [[NSLock alloc] init];
        observedPeripheralIDs = [NSMutableSet set];
        YCYLoadRecords();
        NSLog(@"[YCYUnlock] State initialized frozen=%d records=%lu",
              gCanonicalFrozen, (unsigned long)canonicalWrites.count);
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

/*
 * 强开锁特征：尽量只把真正的开锁帧当成“可冻结的官方开锁”。
 * 弱特征（01 00 / 20 01）握手、心跳、关锁都可能撞上，不能单独用来覆盖记录。
 */
static BOOL YCYLooksLikeStrongUnlock(NSData *data) {
    if (!data || data.length < 3) return NO;
    const unsigned char *b = data.bytes;
    if (data.length >= 3 && b[0] == 0x05 && b[1] == 0x01 && b[2] == 0x06) return YES;
    if (data.length >= 4 && b[0] == 0x06 && b[1] == 0x01 && b[2] == 0x01 && b[3] == 0x01) return YES;
    if (data.length >= 4 && b[0] == 0xAF && b[1] == 0x0F && (b[2] == 0xC0 || b[2] == 0xD0)) return YES;
    if (data.length >= 3 && b[0] == 0xAA && b[1] == 0x55) return YES;
    return NO;
}

static BOOL YCYLooksLikeUnlockPayload(NSData *data) {
    if (!data || data.length < 2) return NO;
    if (YCYLooksLikeStrongUnlock(data)) return YES;
    const unsigned char *b = data.bytes;
    if (b[0] == 0x01 && b[1] == 0x00) return YES;
    if (b[0] == 0x20 && b[1] == 0x01) return YES;
    return NO;
}

static BOOL YCYLooksLikeLockName(NSString *name) {
    if (name.length == 0) return NO;
    NSString *n = name.uppercaseString;
    if ([n containsString:@"YS04"]) return YES;
    if ([n containsString:@"YS0"]) return YES;
    if ([n containsString:@"YISKJ"]) return YES;
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

#pragma mark - 外设池

static void *kYCYStateObs = &kYCYStateObs;

@interface YCYUnlockHelper : NSObject
+ (instancetype)shared;
- (void)onTap;
- (void)onLongPress:(UILongPressGestureRecognizer *)g;
- (void)onPan:(UIPanGestureRecognizer *)g;
@end

static void YCYRememberPeripheral(CBPeripheral *peripheral) {
    if (!peripheral) return;
    NSString *key = peripheral.identifier.UUIDString ?: @"";
    [peripheralLock lock];
    peripheralsByUUID[key] = peripheral;
    [peripheralLock unlock];
    if (YCYLooksLikeLockName(peripheral.name) || lastLockUUID == nil) {
        lastLockUUID = peripheral.identifier;
        lastLockName = YCYPeripheralName(peripheral);
    }
    if (key.length && ![observedPeripheralIDs containsObject:key]) {
        [observedPeripheralIDs addObject:key];
        @try {
            [peripheral addObserver:[YCYUnlockHelper shared]
                         forKeyPath:@"state"
                            options:NSKeyValueObservingOptionNew
                            context:kYCYStateObs];
        } @catch (NSException *ex) {
            YCYLog(@"KVO 失败: %@", ex.reason);
        }
    }
}

static NSArray<CBPeripheral *> *YCYConnectedPeripherals(void) {
    [peripheralLock lock];
    NSArray *all = [peripheralsByUUID allValues];
    [peripheralLock unlock];
    NSMutableArray *connected = [NSMutableArray array];
    for (CBPeripheral *p in all) {
        if (p.state == CBPeripheralStateConnected) {
            [connected addObject:p];
        } else if (p.state == CBPeripheralStateDisconnected) {
            gNeedsRediscover = YES;
        }
    }
    return connected;
}

static CBCharacteristic *YCYFindCharacteristic(CBPeripheral *peripheral, NSString *serviceUUID, NSString *charUUID) {
    (void)serviceUUID;
    if (!peripheral.services) return nil;
    for (CBService *service in peripheral.services) {
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
    if (!peripheral.services) return result;
    for (CBService *service in peripheral.services) {
        if (!service.characteristics) continue;
        for (CBCharacteristic *c in service.characteristics) {
            CBCharacteristicProperties p = c.properties;
            BOOL canWrite = (p & CBCharacteristicPropertyWriteWithoutResponse) ||
                            (p & CBCharacteristicPropertyWrite);
            if (canWrite) [result addObject:c];
        }
    }
    return result;
}

static void YCYEnableNotifies(CBPeripheral *peripheral) {
    if (!peripheral.services) return;
    for (CBService *service in peripheral.services) {
        for (CBCharacteristic *c in service.characteristics) {
            CBCharacteristicProperties p = c.properties;
            if ((p & CBCharacteristicPropertyNotify) || (p & CBCharacteristicPropertyIndicate)) {
                YCYLog(@"开启通知 char=%@", c.UUID.UUIDString);
                [peripheral setNotifyValue:YES forCharacteristic:c];
            }
        }
    }
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.25 animations:^{
                toastLabel.alpha = 0;
            } completion:^(BOOL finished) {
                (void)finished;
                [toastLabel removeFromSuperview];
            }];
        });
    });
}

static void YCYSetButtonBusy(BOOL busy) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!floatButton) return;
        floatButton.enabled = !busy;
        floatButton.alpha = busy ? 0.55 : 1.0;
        [floatButton setTitle:busy ? @"开锁中" : @"开锁" forState:UIControlStateNormal];
    });
}

#pragma mark - 持久化

static NSDictionary *YCYWriteToDict(YCYRecordedWrite *item) {
    return @{
        @"pid": item.peripheralID.UUIDString ?: @"",
        @"name": item.peripheralName ?: @"",
        @"svc": item.serviceUUID ?: @"",
        @"char": item.charUUID ?: @"",
        @"value": [item.value base64EncodedStringWithOptions:0] ?: @"",
        @"type": @(item.type),
        @"time": @([item.time timeIntervalSince1970]),
        @"unlockLike": @(item.unlockLike),
    };
}

static YCYRecordedWrite *YCYWriteFromDict(NSDictionary *d) {
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    YCYRecordedWrite *item = [YCYRecordedWrite new];
    NSString *pid = d[@"pid"];
    if ([pid isKindOfClass:[NSString class]] && pid.length) {
        item.peripheralID = [[NSUUID alloc] initWithUUIDString:pid];
    }
    item.peripheralName = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : @"";
    item.serviceUUID = [d[@"svc"] isKindOfClass:[NSString class]] ? d[@"svc"] : @"";
    item.charUUID = [d[@"char"] isKindOfClass:[NSString class]] ? d[@"char"] : @"";
    NSString *b64 = d[@"value"];
    if ([b64 isKindOfClass:[NSString class]]) {
        item.value = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    }
    item.type = [d[@"type"] integerValue];
    item.time = [NSDate dateWithTimeIntervalSince1970:[d[@"time"] doubleValue]];
    item.unlockLike = [d[@"unlockLike"] boolValue];
    if (!item.value) return nil;
    return item;
}

static void YCYPersistRecords(void) {
    [recordLock lock];
    NSMutableArray *arr = [NSMutableArray array];
    for (YCYRecordedWrite *item in canonicalWrites) {
        [arr addObject:YCYWriteToDict(item)];
    }
    BOOL frozen = gCanonicalFrozen;
    NSString *uuid = lastLockUUID.UUIDString;
    NSString *name = lastLockName;
    [recordLock unlock];

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:arr forKey:kYCYRecordsKey];
    [ud setBool:frozen forKey:@"YCYUnlock.frozen"];
    if (uuid) [ud setObject:uuid forKey:kYCYLockUUIDKey];
    if (name) [ud setObject:name forKey:kYCYLockNameKey];
    [ud synchronize];
}

static void YCYLoadRecords(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *arr = [ud arrayForKey:kYCYRecordsKey];
    [canonicalWrites removeAllObjects];
    for (NSDictionary *d in arr) {
        YCYRecordedWrite *item = YCYWriteFromDict(d);
        if (item) [canonicalWrites addObject:item];
    }
    gCanonicalFrozen = [ud boolForKey:@"YCYUnlock.frozen"] && canonicalWrites.count > 0;
    if (canonicalWrites.count > 0 && !gCanonicalFrozen) {
        for (YCYRecordedWrite *w in canonicalWrites) {
            if (w.unlockLike || YCYLooksLikeUnlockPayload(w.value)) {
                gCanonicalFrozen = YES;
                break;
            }
        }
    }
    NSString *uuid = [ud stringForKey:kYCYLockUUIDKey];
    if (uuid.length) lastLockUUID = [[NSUUID alloc] initWithUUIDString:uuid];
    lastLockName = [ud stringForKey:kYCYLockNameKey];
}

#pragma mark - 记录 / 重放

static NSArray<YCYRecordedWrite *> *YCYCanonicalCopy(void) {
    [recordLock lock];
    NSArray *all = [canonicalWrites copy];
    [recordLock unlock];
    return all;
}

static NSArray<YCYRecordedWrite *> *YCYReplayPackets(NSArray<YCYRecordedWrite *> *burst) {
    NSMutableArray *strong = [NSMutableArray array];
    NSMutableArray *weakUnlock = [NSMutableArray array];
    for (YCYRecordedWrite *item in burst) {
        if (YCYLooksLikeStrongUnlock(item.value) || item.unlockLike) {
            if (YCYLooksLikeStrongUnlock(item.value)) [strong addObject:item];
            else [weakUnlock addObject:item];
        } else if (YCYLooksLikeUnlockPayload(item.value)) {
            [weakUnlock addObject:item];
        }
    }
    if (strong.count) return strong;
    if (weakUnlock.count) return weakUnlock;
    return burst;
}

static void YCYFreezeCanonicalFromSession(void) {
    [recordLock lock];
    BOOL hasUnlock = NO;
    for (YCYRecordedWrite *w in liveSession) {
        if (YCYLooksLikeUnlockPayload(w.value) || YCYLooksLikeStrongUnlock(w.value)) {
            hasUnlock = YES;
            w.unlockLike = YES;
        }
    }
    if (hasUnlock && liveSession.count > 0) {
        [canonicalWrites removeAllObjects];
        [canonicalWrites addObjectsFromArray:liveSession];
        gCanonicalFrozen = YES;
        YCYLog(@"★ 冻结开锁记录 %lu 条（关锁/重连握手不再覆盖）",
               (unsigned long)canonicalWrites.count);
    }
    [recordLock unlock];
    if (hasUnlock) YCYPersistRecords();
}

static void YCYScheduleFreeze(void) {
    if (gFreezeBlock) {
        dispatch_block_cancel(gFreezeBlock);
        gFreezeBlock = nil;
    }
    dispatch_block_t block = dispatch_block_create(0, ^{
        gFreezeBlock = nil;
        if (!gCanonicalFrozen) YCYFreezeCanonicalFromSession();
    });
    gFreezeBlock = block;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), block);
}

static void YCYRecordWrite(CBPeripheral *peripheral,
                           CBCharacteristic *characteristic,
                           NSData *data,
                           CBCharacteristicWriteType type) {
    if (gIgnoreHookWrite) return;
    if (!peripheral || !characteristic || !data) return;

    lastAppPeripheral = peripheral;
    lastAppWriteTime = [NSDate date];
    gNeedsRediscover = NO;

    NSString *charUUID = characteristic.UUID.UUIDString ?: @"";
    BOOL target = YCYIsTargetCharacteristic(charUUID) || YCYLooksLikeUnlockPayload(data);
    if (!target) return;

    /*
     * 关键修复：
     * 旧逻辑只要间隔 > 8 秒就把 canonicalWrites 清空。
     * 关锁、断开重连后的握手都会写 9001，于是官方开锁包被关锁/握手包覆盖。
     * 点悬浮窗时提示“正在重放”，实际重放的已经不是开锁指令，锁当然打不开。
     * 现在：一旦捕获到开锁突发并冻结，后续写包只更新连接状态，不再改记录。
     */
    if (gCanonicalFrozen) {
        YCYLog(@"已冻结，忽略后续写包 char=%@ HEX=%@", charUUID, YCYHexString(data));
        lastLockUUID = peripheral.identifier;
        lastLockName = YCYPeripheralName(peripheral);
        return;
    }

    /* 重连后 2 秒内的写包视为握手，不记入开锁记录。 */
    if (gHandshakeUntil && [gHandshakeUntil timeIntervalSinceNow] > 0) {
        YCYLog(@"握手窗口内，跳过记录 char=%@ HEX=%@", charUUID, YCYHexString(data));
        lastLockUUID = peripheral.identifier;
        lastLockName = YCYPeripheralName(peripheral);
        return;
    }

    YCYRecordedWrite *item = [YCYRecordedWrite new];
    item.peripheralID = peripheral.identifier;
    item.peripheralName = YCYPeripheralName(peripheral);
    item.serviceUUID = characteristic.service.UUID.UUIDString ?: @"";
    item.charUUID = charUUID;
    item.value = [data copy];
    item.type = type;
    item.time = [NSDate date];
    item.unlockLike = YCYLooksLikeUnlockPayload(data);

    lastLockUUID = peripheral.identifier;
    lastLockName = item.peripheralName;

    [recordLock lock];
    YCYRecordedWrite *last = liveSession.lastObject;
    if (last && [item.time timeIntervalSinceDate:last.time] > 8.0) {
        [liveSession removeAllObjects];
    }
    BOOL dup = NO;
    if (liveSession.count > 0) {
        YCYRecordedWrite *prev = liveSession.lastObject;
        if ([prev.charUUID isEqualToString:item.charUUID] &&
            [prev.value isEqualToData:item.value]) {
            dup = YES;
        }
    }
    if (!dup) {
        [liveSession addObject:item];
        if (liveSession.count > 12) {
            [liveSession removeObjectsInRange:NSMakeRange(0, liveSession.count - 12)];
        }
    }
    BOOL shouldPromote = NO;
    for (YCYRecordedWrite *w in liveSession) {
        if (YCYLooksLikeUnlockPayload(w.value) || YCYLooksLikeStrongUnlock(w.value)) {
            shouldPromote = YES;
            break;
        }
    }
    if (shouldPromote) {
        [canonicalWrites removeAllObjects];
        [canonicalWrites addObjectsFromArray:liveSession];
    }
    NSUInteger count = canonicalWrites.count;
    [recordLock unlock];

    if (!dup) {
        YCYLog(@"★ 记录开锁包 #%lu name=%@ char=%@ HEX=%@",
               (unsigned long)count, item.peripheralName, item.charUUID, YCYHexString(data));
    }
    if (shouldPromote) {
        YCYScheduleFreeze();
        YCYPersistRecords();
    }
}

static CBCharacteristicWriteType YCYResolvedType(CBCharacteristic *characteristic,
                                                 CBCharacteristicWriteType preferred) {
    BOOL canWith = (characteristic.properties & CBCharacteristicPropertyWrite) != 0;
    BOOL canWithout = (characteristic.properties & CBCharacteristicPropertyWriteWithoutResponse) != 0;
    if (preferred == CBCharacteristicWriteWithResponse) {
        if (canWith) return CBCharacteristicWriteWithResponse;
        if (canWithout) return CBCharacteristicWriteWithoutResponse;
    } else {
        if (canWithout) return CBCharacteristicWriteWithoutResponse;
        if (canWith) return CBCharacteristicWriteWithResponse;
    }
    return canWith ? CBCharacteristicWriteWithResponse : CBCharacteristicWriteWithoutResponse;
}

static BOOL YCYWriteData(CBPeripheral *peripheral,
                         CBCharacteristic *characteristic,
                         NSData *data,
                         CBCharacteristicWriteType preferred) {
    if (!peripheral || !characteristic || !data) return NO;
    if (peripheral.state != CBPeripheralStateConnected) {
        YCYLog(@"写入跳过：未连接 name=%@", YCYPeripheralName(peripheral));
        return NO;
    }

    CBCharacteristicWriteType type = YCYResolvedType(characteristic, preferred);

    @try {
        [peripheral writeValue:data forCharacteristic:characteristic type:type];
        YCYLog(@"已写入 name=%@ char=%@ type=%@ len=%lu HEX=%@",
               YCYPeripheralName(peripheral),
               characteristic.UUID.UUIDString,
               type == CBCharacteristicWriteWithResponse ? @"WithResponse" : @"WithoutResponse",
               (unsigned long)data.length,
               YCYHexString(data));
        return YES;
    } @catch (NSException *ex) {
        YCYLog(@"写入异常: %@", ex.reason);
        return NO;
    }
}

static CBPeripheral *YCYPickPeripheral(NSArray<CBPeripheral *> *connected, NSUUID *preferID) {
    CBPeripheral *appP = lastAppPeripheral;
    if (appP && appP.state == CBPeripheralStateConnected) return appP;
    if (preferID) {
        for (CBPeripheral *p in connected) {
            if ([p.identifier isEqual:preferID]) return p;
        }
    }
    for (CBPeripheral *p in connected) {
        if (YCYLooksLikeLockName(p.name)) return p;
    }
    return connected.firstObject;
}

static CBCharacteristic *YCYPickWriteChar(CBPeripheral *target, YCYRecordedWrite *item) {
    CBCharacteristic *ch = YCYFindCharacteristic(target, item.serviceUUID, item.charUUID);
    if (ch) return ch;
    for (CBCharacteristic *c in YCYWriteCharacteristics(target)) {
        if (YCYIsTargetCharacteristic(c.UUID.UUIDString)) return c;
    }
    return YCYWriteCharacteristics(target).firstObject;
}

static void YCYFinishUnlockFlight(void) {
    gIgnoreHookWrite = NO;
    gUnlockInFlight = NO;
    YCYSetButtonBusy(NO);
}

static NSInteger YCYReplayBurstOnPeripheral(NSArray<YCYRecordedWrite *> *burst, CBPeripheral *forced) {
    if (burst.count == 0) {
        YCYFinishUnlockFlight();
        return 0;
    }

    NSArray<YCYRecordedWrite *> *packets = YCYReplayPackets(burst);
    YCYLog(@"开始重放 packets=%lu / recorded=%lu needsRediscover=%d",
           (unsigned long)packets.count, (unsigned long)burst.count, gNeedsRediscover);

    gIgnoreHookWrite = YES;
    YCYEnableNotifies(forced);

    NSArray *connected = YCYConnectedPeripherals();
    NSMutableArray *pool = [connected mutableCopy] ?: [NSMutableArray array];
    if (forced && forced.state == CBPeripheralStateConnected) {
        BOOL exists = NO;
        for (CBPeripheral *p in pool) {
            if (p == forced || [p.identifier isEqual:forced.identifier]) { exists = YES; break; }
        }
        if (!exists) [pool addObject:forced];
    }

    __block NSInteger sent = 0;
    void (^sendOne)(YCYRecordedWrite *) = ^(YCYRecordedWrite *item) {
        CBPeripheral *target = YCYPickPeripheral(pool, item.peripheralID ?: lastLockUUID);
        if (!target) target = forced;
        if (!target || target.state != CBPeripheralStateConnected) {
            YCYLog(@"重放失败：没有可用设备");
            return;
        }
        CBCharacteristic *ch = YCYPickWriteChar(target, item);
        if (!ch) {
            YCYLog(@"重放失败：找不到可写特征 %@", item.charUUID);
            return;
        }
        if (YCYWriteData(target, ch, item.value, item.type)) sent++;
    };

    NSTimeInterval gap = 0.14;
    for (NSUInteger i = 0; i < packets.count; i++) {
        YCYRecordedWrite *item = packets[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * gap * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            sendOne(item);
        });
    }

    /* 末包再补一次，应对 WriteWithoutResponse 在重连后偶发丢失；不会把整段突发连放三遍。 */
    YCYRecordedWrite *lastPkt = packets.lastObject;
    NSTimeInterval extraAt = packets.count * gap + 0.28;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(extraAt * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (lastPkt) sendOne(lastPkt);
    });

    NSTimeInterval total = extraAt + 0.7;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(total * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YCYLog(@"重放结束 sent≈%ld", (long)sent);
        YCYFinishUnlockFlight();
    });
    return (NSInteger)packets.count;
}

#pragma mark - 自建 BLE 连接

@interface YCYBleEngine : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@property (nonatomic, strong) CBCentralManager *central;
@property (nonatomic, strong) CBPeripheral *target;
@property (nonatomic, copy) NSArray<YCYRecordedWrite *> *pendingBurst;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) BOOL replayed;
@property (nonatomic, assign) NSInteger pendingDiscover;
@property (nonatomic, assign) NSUInteger generation;
@end

static YCYBleEngine *gEngine;

@implementation YCYBleEngine

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gEngine = [YCYBleEngine new]; });
    return gEngine;
}

- (void)failWith:(NSString *)msg {
    YCYLog(@"连接流程失败: %@", msg);
    self.busy = NO;
    self.replayed = YES;
    YCYFinishUnlockFlight();
    [self.central stopScan];
    YCYShowToast(msg);
}

- (void)finishReplayOn:(CBPeripheral *)peripheral {
    if (self.replayed) return;
    self.replayed = YES;
    self.busy = NO;
    [self.central stopScan];
    NSInteger n = YCYReplayBurstOnPeripheral(self.pendingBurst, peripheral);
    YCYShowToast([NSString stringWithFormat:@"已连接，正在重放 %ld 条指令", (long)n]);
}

- (BOOL)hasWriteChars:(CBPeripheral *)p {
    return YCYWriteCharacteristics(p).count > 0;
}

- (void)discoverOn:(CBPeripheral *)peripheral {
    self.target = peripheral;
    peripheral.delegate = self;
    YCYLog(@"开始发现服务（强制刷新，不信任缓存） %@", YCYPeripheralName(peripheral));
    /*
     * 重连后 retrieve 回来的 CBPeripheral 往往还挂着上一次的 services，
     * 那些特征已经失效，直接 write 会静默失败：界面显示已连接+正在重放，锁却不动。
     * 所以这里永远重新 discover，禁止走缓存短路径。
     */
    NSArray *svcs = @[
        [CBUUID UUIDWithString:kYCYSvc9000],
        [CBUUID UUIDWithString:kYCYSvcAE00]
    ];
    [peripheral discoverServices:svcs];
    __weak typeof(self) weakSelf = self;
    NSUInteger gen = self.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (weakSelf.generation != gen) return;
        if (!weakSelf.replayed && peripheral.services.count == 0) {
            [peripheral discoverServices:nil];
        }
    });
}

- (void)connectPeripheral:(CBPeripheral *)peripheral {
    if (!peripheral) return;
    YCYLog(@"正在连接 %@ %@", YCYPeripheralName(peripheral), peripheral.identifier.UUIDString);
    YCYShowToast([NSString stringWithFormat:@"正在连接 %@", YCYPeripheralName(peripheral)]);
    self.target = peripheral;
    [self.central stopScan];
    [self.central connectPeripheral:peripheral options:nil];
}

- (void)beginWithBurst:(NSArray<YCYRecordedWrite *> *)burst {
    self.pendingBurst = burst;
    self.replayed = NO;
    self.busy = YES;
    self.target = nil;
    self.pendingDiscover = 0;
    self.generation += 1;
    NSUInteger gen = self.generation;

    if (!self.central) {
        self.central = [[CBCentralManager alloc] initWithDelegate:self
                                                            queue:dispatch_get_main_queue()
                                                          options:@{CBCentralManagerOptionShowPowerAlertKey: @YES}];
    } else {
        [self centralManagerDidUpdateState:self.central];
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.generation == gen && self.busy && !self.replayed) {
            [self failWith:@"搜索锁盒超时\n请把 YS04 靠近手机后再试"];
        }
    });
}

- (void)tryRetrieveAndScan {
    CBCentralManager *c = self.central;

    NSMutableArray *ids = [NSMutableArray array];
    if (lastLockUUID) [ids addObject:lastLockUUID];
    for (YCYRecordedWrite *w in self.pendingBurst) {
        if (w.peripheralID) [ids addObject:w.peripheralID];
    }

    if (appCentral) {
        YCYLog(@"appCentral state=%ld", (long)appCentral.state);
    }
    if (lastLockName) {
        YCYLog(@"lastLock name=%@", lastLockName);
    }

    NSArray *svcs = @[
        [CBUUID UUIDWithString:kYCYSvc9000],
        [CBUUID UUIDWithString:kYCYSvcAE00]
    ];

    if (ids.count > 0) {
        NSArray *known = [c retrievePeripheralsWithIdentifiers:ids];
        YCYLog(@"retrievePeripherals count=%lu", (unsigned long)known.count);
        if (known.count > 0) {
            [self connectPeripheral:known.firstObject];
            return;
        }
    }

    NSArray *already = [c retrieveConnectedPeripheralsWithServices:svcs];
    YCYLog(@"retrieveConnected count=%lu", (unsigned long)already.count);
    if (already.count > 0) {
        CBPeripheral *pick = already.firstObject;
        for (CBPeripheral *p in already) {
            if (YCYLooksLikeLockName(p.name)) { pick = p; break; }
        }
        if (pick.state == CBPeripheralStateConnected) {
            [self discoverOn:pick];
        } else {
            [self connectPeripheral:pick];
        }
        return;
    }

    YCYLog(@"开始扫描 YS04");
    YCYShowToast(@"正在搜索 YS04…");
    [c scanForPeripheralsWithServices:nil
                              options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (central.state != CBManagerStatePoweredOn) {
        if (self.busy) {
            [self failWith:@"系统蓝牙未打开"];
        }
        return;
    }
    if (self.busy && !self.replayed) {
        [self tryRetrieveAndScan];
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *,id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    (void)central;
    NSString *name = peripheral.name.length
        ? peripheral.name
        : advertisementData[CBAdvertisementDataLocalNameKey];
    YCYLog(@"扫描到 name=%@ uuid=%@ rssi=%@", name, peripheral.identifier.UUIDString, RSSI);

    BOOL match = YCYLooksLikeLockName(name);
    if (!match && lastLockUUID && [peripheral.identifier isEqual:lastLockUUID]) match = YES;
    for (YCYRecordedWrite *w in self.pendingBurst) {
        if (w.peripheralID && [peripheral.identifier isEqual:w.peripheralID]) match = YES;
    }
    if (!match) return;

    [self connectPeripheral:peripheral];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    (void)central;
    YCYLog(@"已连接 %@", YCYPeripheralName(peripheral));
    [self discoverOn:peripheral];
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    (void)central;
    (void)peripheral;
    [self failWith:[NSString stringWithFormat:@"连接失败: %@", error.localizedDescription ?: @"未知错误"]];
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    (void)central;
    YCYLog(@"engine 断开 %@ err=%@", YCYPeripheralName(peripheral), error);
    gNeedsRediscover = YES;
    if (self.busy && !self.replayed) {
        [self failWith:@"连接被断开，请靠近锁盒再试"];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (error) {
        YCYLog(@"发现服务失败 %@", error);
    }
    self.pendingDiscover = 0;
    if (peripheral.services.count == 0) {
        [self failWith:@"已连接但没有发现服务"];
        return;
    }
    for (CBService *s in peripheral.services) {
        self.pendingDiscover++;
        [peripheral discoverCharacteristics:nil forService:s];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(NSError *)error {
    (void)service;
    (void)error;
    self.pendingDiscover--;
    if (self.pendingDiscover <= 0 && !self.replayed) {
        if ([self hasWriteChars:peripheral]) {
            YCYEnableNotifies(peripheral);
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf finishReplayOn:peripheral];
            });
        } else {
            [self failWith:@"已连接但没有可写特征"];
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didWriteValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    (void)peripheral;
    if (error) {
        YCYLog(@"写入回调失败 char=%@ err=%@", characteristic.UUID.UUIDString, error);
    } else {
        YCYLog(@"写入回调成功 char=%@", characteristic.UUID.UUIDString);
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    (void)error;
    YCYLog(@"通知 name=%@ char=%@ HEX=%@",
           YCYPeripheralName(peripheral),
           characteristic.UUID.UUIDString,
           YCYHexString(characteristic.value));
}

@end

#pragma mark - 开锁入口

static void YCYDoReplay(NSArray *burst, CBPeripheral *ready) {
    NSInteger n = YCYReplayBurstOnPeripheral(burst, ready);
    YCYShowToast([NSString stringWithFormat:@"正在重放 %ld 条指令", (long)n]);
}

static void YCYTryUnlock(void) {
    YCYInitState();
    if (gUnlockInFlight) {
        YCYShowToast(@"正在开锁，请稍候");
        return;
    }

    NSArray *burst = YCYCanonicalCopy();
    NSArray *connected = YCYConnectedPeripherals();

    YCYLog(@"尝试开锁 connected=%lu canonical=%lu frozen=%d needsRediscover=%d",
           (unsigned long)connected.count,
           (unsigned long)burst.count,
           gCanonicalFrozen,
           gNeedsRediscover);

    if (burst.count == 0) {
        YCYShowToast(@"还没有记录到开锁指令\n请先让控方同意并成功开锁一次");
        return;
    }

    gUnlockInFlight = YES;
    YCYSetButtonBusy(YES);

    CBPeripheral *ready = YCYPickPeripheral(connected, lastLockUUID);

    if (ready && ready.state == CBPeripheralStateConnected) {
        BOOL hasChars = YCYWriteCharacteristics(ready).count > 0;
        NSTimeInterval sinceWrite = lastAppWriteTime
            ? -[lastAppWriteTime timeIntervalSinceNow]
            : 999;
        BOOL recentlyWritten = sinceWrite < 8.0;

        if (hasChars && !gNeedsRediscover && recentlyWritten) {
            YCYDoReplay(burst, ready);
            return;
        }

        /* 关锁/重连后特征可能是缓存，先让 App 侧对象重新发现再写。 */
        YCYLog(@"已连接但需刷新服务 hasChars=%d needsRediscover=%d sinceWrite=%.1f",
               hasChars, gNeedsRediscover, sinceWrite);
        YCYShowToast(@"锁盒已连接，正在刷新服务…");
        [ready discoverServices:nil];
        __weak CBPeripheral *weakP = ready;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CBPeripheral *p = weakP;
            if (!p || p.state != CBPeripheralStateConnected) {
                YCYShowToast(@"锁盒未连接，正在自动搜索 YS04…");
                [[YCYBleEngine shared] beginWithBurst:burst];
                return;
            }
            if (p.services.count == 0) {
                [p discoverServices:@[
                    [CBUUID UUIDWithString:kYCYSvc9000],
                    [CBUUID UUIDWithString:kYCYSvcAE00]
                ]];
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                CBPeripheral *p2 = weakP;
                if (p2 && p2.state == CBPeripheralStateConnected &&
                    YCYWriteCharacteristics(p2).count > 0) {
                    gNeedsRediscover = NO;
                    YCYDoReplay(burst, p2);
                } else {
                    YCYShowToast(@"锁盒未连接，正在自动搜索 YS04…");
                    [[YCYBleEngine shared] beginWithBurst:burst];
                }
            });
        });
        return;
    }

    YCYShowToast(@"锁盒未连接，正在自动搜索 YS04…");
    [[YCYBleEngine shared] beginWithBurst:burst];
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
        NSArray *all = YCYCanonicalCopy();
        NSMutableString *text = [NSMutableString string];
        if (all.count == 0) {
            [text appendString:@"暂无已记录的开锁指令\n请先让控方正常同意并成功开锁一次"];
        } else {
            [text appendFormat:@"状态：%@\n\n", gCanonicalFrozen ? @"已冻结（关锁不会覆盖）" : @"采集中"];
            NSInteger i = 1;
            for (YCYRecordedWrite *item in all) {
                [text appendFormat:@"%ld. %@ char=%@ len=%lu%@\n%@\n\n",
                 (long)i++,
                 item.peripheralName,
                 item.charUUID,
                 (unsigned long)item.value.length,
                 item.unlockLike ? @"  [开锁]" : @"",
                 YCYHexString(item.value)];
            }
        }

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"已记录指令（仅一次官方开锁）"
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
    if (gFreezeBlock) {
        dispatch_block_cancel(gFreezeBlock);
        gFreezeBlock = nil;
    }
    [recordLock lock];
    [canonicalWrites removeAllObjects];
    [liveSession removeAllObjects];
    gCanonicalFrozen = NO;
    [recordLock unlock];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud removeObjectForKey:kYCYRecordsKey];
    [ud setBool:NO forKey:@"YCYUnlock.frozen"];
    [ud synchronize];
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

static void YCYShowMenu(UIButton *sender) {
    NSArray *canon = YCYCanonicalCopy();
    NSString *msg = [NSString stringWithFormat:
        @"短按：开锁（未连接会自动搜 YS04）\n长按：本菜单\n监控：%@   记录：%lu 条%@\n已连接：%lu",
        monitorEnabled ? @"开" : @"关",
        (unsigned long)canon.count,
        gCanonicalFrozen ? @"（已冻结）" : @"",
        (unsigned long)YCYConnectedPeripherals().count];

    UIAlertController *menu =
        [UIAlertController alertControllerWithTitle:@"YCY Unlock"
                                            message:msg
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    [menu addAction:[UIAlertAction actionWithTitle:@"立即开锁"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *a) {
                                               (void)a;
                                               YCYTryUnlock();
                                           }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"查看已记录指令"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
                                               (void)a;
                                               YCYShowRecords();
                                           }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"查看 BLE 日志"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
                                               (void)a;
                                               YCYShowLogs();
                                           }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"复制 BLE 日志"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
                                               (void)a;
                                               YCYCopyLogs();
                                           }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"清空日志"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
                                               (void)a;
                                               YCYClearLogs();
                                           }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"清空开锁记录"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
                                               (void)a;
                                               YCYClearRecords();
                                           }]];
    [menu addAction:[UIAlertAction
        actionWithTitle:monitorEnabled ? @"关闭监控" : @"开启监控"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *a) {
                    (void)a;
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

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if (context != kYCYStateObs) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    if (![object isKindOfClass:[CBPeripheral class]]) return;
    CBPeripheral *p = (CBPeripheral *)object;
    NSInteger state = p.state;
    YCYLog(@"外设状态变化 name=%@ state=%ld", YCYPeripheralName(p), (long)state);
    if (state == CBPeripheralStateDisconnected ||
        state == CBPeripheralStateConnecting) {
        gNeedsRediscover = YES;
        if (lastAppPeripheral == p) lastAppPeripheral = nil;
    }
    if (state == CBPeripheralStateConnected) {
        gNeedsRediscover = YES;
    }
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

- (instancetype)initWithDelegate:(id<CBCentralManagerDelegate>)delegate
                           queue:(dispatch_queue_t)queue
                         options:(NSDictionary *)options {
    CBCentralManager *obj = %orig;
    if (obj && delegate && ![delegate isKindOfClass:[YCYBleEngine class]]) {
        appCentral = obj;
    }
    return obj;
}

- (void)scanForPeripheralsWithServices:(NSArray<CBUUID *> *)serviceUUIDs
                               options:(NSDictionary<NSString *,id> *)options {
    if (![self.delegate isKindOfClass:[YCYBleEngine class]]) {
        appCentral = self;
    }
    if (monitorEnabled) {
        NSMutableArray *uuids = [NSMutableArray array];
        for (CBUUID *uuid in serviceUUIDs) [uuids addObject:uuid.UUIDString];
        YCYLog(@"scan services=%@ options=%@", uuids, options);
    }
    %orig;
}

- (void)stopScan {
    if (monitorEnabled && ![self.delegate isKindOfClass:[YCYBleEngine class]]) {
        YCYLog(@"stopScan");
    }
    %orig;
}

- (void)connectPeripheral:(CBPeripheral *)peripheral
                  options:(NSDictionary<NSString *,id> *)options {
    YCYRememberPeripheral(peripheral);
    gNeedsRediscover = YES;
    gHandshakeUntil = [NSDate dateWithTimeIntervalSinceNow:2.0];
    if (![self.delegate isKindOfClass:[YCYBleEngine class]]) {
        appCentral = self;
    }
    if (monitorEnabled) {
        YCYLog(@"connect name=%@ UUID=%@",
               YCYPeripheralName(peripheral),
               YCYUUIDString(peripheral.identifier));
    }
    %orig;
}

- (void)cancelPeripheralConnection:(CBPeripheral *)peripheral {
    gNeedsRediscover = YES;
    if (lastAppPeripheral == peripheral) lastAppPeripheral = nil;
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
    YCYLog(@"YCYUnlock loaded v1.1.0");
    YCYLog(@"短按 = 开锁（未连接会自动搜 YS04）");
    YCYLog(@"长按 = 菜单 / 日志");
    YCYLog(@"开锁记录冻结后，关锁/重连不会覆盖");
    YCYLog(@"==============================");
    YCYScheduleFloatingButton();
}

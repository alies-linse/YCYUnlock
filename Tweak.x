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
static BOOL gIgnoreHookWrite = NO;
static BOOL gUnlockInFlight = NO;

static NSMutableSet<CBPeripheral *> *knownPeripherals;
static NSLock *peripheralLock;
static CBCentralManager *appCentral;
static NSUUID *lastLockUUID;
static NSString *lastLockName;

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

static NSMutableArray<YCYRecordedWrite *> *canonicalWrites;
static NSLock *recordLock;

#pragma mark - 工具

static void YCYInitState(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bleLogs = [NSMutableArray array];
        bleLogLock = [[NSLock alloc] init];
        canonicalWrites = [NSMutableArray array];
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

static BOOL YCYLooksLikeUnlockPayload(NSData *data) {
    if (!data || data.length < 2) return NO;
    const unsigned char *b = data.bytes;
    if (b[0] == 0x01 && b[1] == 0x00) return YES;
    if (b[0] == 0x20 && b[1] == 0x01) return YES;
    if (data.length >= 3 && b[0] == 0x05 && b[1] == 0x01 && b[2] == 0x06) return YES;
    if (data.length >= 4 && b[0] == 0x06 && b[1] == 0x01 && b[2] == 0x01 && b[3] == 0x01) return YES;
    if (data.length >= 4 && b[0] == 0xAF && b[1] == 0x0F && (b[2] == 0xC0 || b[2] == 0xD0)) return YES;
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

static void YCYRememberPeripheral(CBPeripheral *peripheral) {
    if (!peripheral) return;
    [peripheralLock lock];
    [knownPeripherals addObject:peripheral];
    [peripheralLock unlock];
    if (YCYLooksLikeLockName(peripheral.name) || lastLockUUID == nil) {
        lastLockUUID = peripheral.identifier;
        lastLockName = YCYPeripheralName(peripheral);
    }
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

#pragma mark - 记录 / 重放

static NSArray<YCYRecordedWrite *> *YCYCanonicalCopy(void) {
    [recordLock lock];
    NSArray *all = [canonicalWrites copy];
    [recordLock unlock];
    return all;
}

static void YCYRecordWrite(CBPeripheral *peripheral,
                           CBCharacteristic *characteristic,
                           NSData *data,
                           CBCharacteristicWriteType type) {
    if (gIgnoreHookWrite) return;
    if (!peripheral || !characteristic || !data) return;

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

    lastLockUUID = peripheral.identifier;
    lastLockName = item.peripheralName;

    [recordLock lock];
    YCYRecordedWrite *last = canonicalWrites.lastObject;
    BOOL newSession = (canonicalWrites.count == 0);
    if (last && [item.time timeIntervalSinceDate:last.time] > 8.0) {
        newSession = YES;
    }
    if (newSession) {
        [canonicalWrites removeAllObjects];
    }
    BOOL dup = NO;
    if (canonicalWrites.count > 0) {
        YCYRecordedWrite *prev = canonicalWrites.lastObject;
        if ([prev.charUUID isEqualToString:item.charUUID] &&
            [prev.value isEqualToData:item.value]) {
            dup = YES;
        }
    }
    if (!dup) {
        [canonicalWrites addObject:item];
        if (canonicalWrites.count > 8) {
            [canonicalWrites removeObjectsInRange:NSMakeRange(0, canonicalWrites.count - 8)];
        }
    }
    NSUInteger count = canonicalWrites.count;
    [recordLock unlock];

    if (!dup) {
        YCYLog(@"★ 记录开锁包 #%lu name=%@ char=%@ HEX=%@",
               (unsigned long)count, item.peripheralName, item.charUUID, YCYHexString(data));
    }
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

static CBPeripheral *YCYPickPeripheral(NSArray<CBPeripheral *> *connected, NSUUID *preferID) {
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

static NSInteger YCYReplayBurstOnPeripheral(NSArray<YCYRecordedWrite *> *burst, CBPeripheral *forced) {
    if (burst.count == 0) return 0;

    gIgnoreHookWrite = YES;

    NSArray *connected = YCYConnectedPeripherals();
    NSMutableArray *pool = [connected mutableCopy] ?: [NSMutableArray array];
    if (forced && forced.state == CBPeripheralStateConnected) {
        BOOL exists = NO;
        for (CBPeripheral *p in pool) {
            if (p == forced || [p.identifier isEqual:forced.identifier]) { exists = YES; break; }
        }
        if (!exists) [pool addObject:forced];
    }

    void (^sendOne)(YCYRecordedWrite *) = ^(YCYRecordedWrite *item) {
        CBPeripheral *target = YCYPickPeripheral(pool, item.peripheralID ?: lastLockUUID);
        if (!target) target = forced;
        if (!target) {
            YCYLog(@"重放失败：没有可用设备");
            return;
        }
        CBCharacteristic *ch = YCYPickWriteChar(target, item);
        if (!ch) {
            YCYLog(@"重放失败：找不到可写特征 %@", item.charUUID);
            return;
        }
        YCYWriteData(target, ch, item.value);
    };

    NSTimeInterval total = burst.count * 0.12 + 0.8;
    for (NSUInteger i = 0; i < burst.count; i++) {
        YCYRecordedWrite *item = burst[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.12 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            sendOne(item);
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(total * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gIgnoreHookWrite = NO;
        gUnlockInFlight = NO;
    });
    return (NSInteger)burst.count;
}

#pragma mark - 自建 BLE 连接

@interface YCYBleEngine : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@property (nonatomic, strong) CBCentralManager *central;
@property (nonatomic, strong) CBPeripheral *target;
@property (nonatomic, copy) NSArray<YCYRecordedWrite *> *pendingBurst;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) BOOL replayed;
@property (nonatomic, assign) NSInteger pendingDiscover;
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
    gUnlockInFlight = NO;
    gIgnoreHookWrite = NO;
    [self.central stopScan];
    YCYShowToast(msg);
}

- (void)finishReplayOn:(CBPeripheral *)peripheral {
    if (self.replayed) return;
    self.replayed = YES;
    self.busy = NO;
    [self.central stopScan];
    YCYRememberPeripheral(peripheral);
    NSInteger n = YCYReplayBurstOnPeripheral(self.pendingBurst, peripheral);
    YCYShowToast([NSString stringWithFormat:@"已连接，正在重放 %ld 条指令", (long)n]);
}

- (BOOL)hasWriteChars:(CBPeripheral *)p {
    return YCYWriteCharacteristics(p).count > 0;
}

- (void)discoverOn:(CBPeripheral *)peripheral {
    self.target = peripheral;
    peripheral.delegate = self;
    YCYRememberPeripheral(peripheral);
    if ([self hasWriteChars:peripheral]) {
        [self finishReplayOn:peripheral];
        return;
    }
    YCYLog(@"开始发现服务 %@", YCYPeripheralName(peripheral));
    NSArray *svcs = @[
        [CBUUID UUIDWithString:kYCYSvc9000],
        [CBUUID UUIDWithString:kYCYSvcAE00]
    ];
    [peripheral discoverServices:svcs];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.replayed && peripheral.services.count == 0) {
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

    if (!self.central) {
        self.central = [[CBCentralManager alloc] initWithDelegate:self
                                                            queue:dispatch_get_main_queue()
                                                          options:@{CBCentralManagerOptionShowPowerAlertKey: @YES}];
    } else {
        [self centralManagerDidUpdateState:self.central];
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.busy && !self.replayed) {
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
            [self finishReplayOn:peripheral];
        } else {
            [self failWith:@"已连接但没有可写特征"];
        }
    }
}

@end

static void YCYTryUnlock(void) {
    YCYInitState();
    if (gUnlockInFlight) {
        YCYShowToast(@"正在开锁，请稍候");
        return;
    }

    NSArray *burst = YCYCanonicalCopy();
    NSArray *connected = YCYConnectedPeripherals();

    YCYLog(@"尝试开锁 connected=%lu canonical=%lu",
           (unsigned long)connected.count,
           (unsigned long)burst.count);

    if (burst.count == 0) {
        YCYShowToast(@"还没有记录到开锁指令\n请先让控方同意并成功开锁一次");
        return;
    }

    gUnlockInFlight = YES;

    CBPeripheral *ready = YCYPickPeripheral(connected, lastLockUUID);
    if (ready && ready.state == CBPeripheralStateConnected &&
        YCYWriteCharacteristics(ready).count > 0) {
        NSInteger n = YCYReplayBurstOnPeripheral(burst, ready);
        YCYShowToast([NSString stringWithFormat:@"正在重放 %ld 条指令", (long)n]);
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
    [recordLock lock];
    [canonicalWrites removeAllObjects];
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
    NSArray *canon = YCYCanonicalCopy();
    NSString *msg = [NSString stringWithFormat:
        @"短按：开锁（未连接会自动搜 YS04）\n长按：本菜单\n监控：%@   记录：%lu 条\n已连接：%lu",
        monitorEnabled ? @"开" : @"关",
        (unsigned long)canon.count,
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
    YCYLog(@"短按 = 开锁（未连接会自动搜 YS04）");
    YCYLog(@"长按 = 菜单 / 日志");
    YCYLog(@"==============================");
    YCYScheduleFloatingButton();
}

#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <QuartzCore/QuartzCore.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <objc/runtime.h>

/*
 * YCYUnlock v1.3.1 (断电重连修复版)
 *
 * 日志结论（断电失败）：
 * - 握手是：WRITE 13 35…（跨会话不变）→ NOTIFY 挑战 → WRITE 4B 58… + 9B 17…（会话密文）
 * - v1.2 把握手后两包冻成「开锁」，同连接重放能收到通知；断电后挑战变了，旧密文被锁忽略（无 NOTIFY）
 * - JS _ble_do 不在全局（miss）；原生类是 DCBLEManager
 *
 * v1.3.1 修复：
 * 1. 扩充 DCBLEManager 原生方法契约与入参，提高命中概率。
 * 2. 精准判断同会话（移除死板的 15 秒空闲拦截）。
 * 3. 断电重连加入基于握手标志位（gHandshakeWritesLeft）的状态轮询检测，完成新 Challenge 后自动开锁。
 */

#pragma mark - 常量（YS04 / Walkiz）

static NSString * const kYCYChar9001 = @"00009001-0000-1000-8000-57616C6B697A";
static NSString * const kYCYCharAE01 = @"AE01";
static NSString * const kYCYSvc9000  = @"00009000-0000-1000-8000-57616C6B697A";
static NSString * const kYCYSvcAE00  = @"AE00";
static NSString * const kYCYRecordsKey = @"YCYUnlock.canonicalWrites.v3";
static NSString * const kYCYRecordsKeyV2 = @"YCYUnlock.canonicalWrites.v2";
static NSString * const kYCYLockUUIDKey = @"YCYUnlock.lastLockUUID";
static NSString * const kYCYLockNameKey = @"YCYUnlock.lastLockName";
static NSString * const kYCYVersion = @"1.3.1";

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
static BOOL gInJSProbe = NO;
static BOOL gDumpedClasses = NO;
static BOOL gDumpedDCBLE = NO;
static NSDate *gHandshakeUntil;
static NSInteger gHandshakeWritesLeft = 0;
static NSUInteger gSessionGen = 0;
static NSUInteger gFrozenSessionGen = 0;

static NSMutableDictionary<NSString *, CBPeripheral *> *peripheralsByUUID;
static NSLock *peripheralLock;
static CBCentralManager *appCentral;
static NSUUID *lastLockUUID;
static NSString *lastLockName;
static __weak CBPeripheral *lastAppPeripheral;
static __weak id gDCBLE;
static NSDate *lastAppWriteTime;
static NSMutableSet<NSString *> *observedPeripheralIDs;
static NSHashTable<JSContext *> *jsContexts;

@interface YCYRecordedWrite : NSObject
@property (nonatomic, copy) NSUUID *peripheralID;
@property (nonatomic, copy) NSString *peripheralName;
@property (nonatomic, copy) NSString *serviceUUID;
@property (nonatomic, copy) NSString *charUUID;
@property (nonatomic, copy) NSData *value;
@property (nonatomic, assign) CBCharacteristicWriteType type;
@property (nonatomic, strong) NSDate *time;
@property (nonatomic, assign) BOOL unlockLike;
@property (nonatomic, assign) BOOL handshakeLike;
@property (nonatomic, assign) BOOL heartbeatLike;
@property (nonatomic, assign) NSUInteger seenCount;
@end

@implementation YCYRecordedWrite
@end

static NSMutableArray<YCYRecordedWrite *> *canonicalWrites;
static NSMutableArray<YCYRecordedWrite *> *liveSession;
static NSMutableDictionary<NSString *, NSNumber *> *payloadCounts;
static NSLock *recordLock;
static dispatch_block_t gFreezeBlock;

#pragma mark - 工具

static void YCYPersistRecords(void);
static void YCYLoadRecords(void);
static void YCYScheduleFloatingButton(void);
static NSArray<YCYRecordedWrite *> *YCYUniqueUnlockPackets(NSArray<YCYRecordedWrite *> *burst);
static void YCYReclassifyInPlace(NSMutableArray<YCYRecordedWrite *> *items);
static void YCYDumpClassDetailed(Class cls);
static void YCYShowToast(NSString *text);
static void YCYRememberPeripheral(CBPeripheral *peripheral);

static void YCYInitState(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bleLogs = [NSMutableArray array];
        bleLogLock = [[NSLock alloc] init];
        canonicalWrites = [NSMutableArray array];
        liveSession = [NSMutableArray array];
        payloadCounts = [NSMutableDictionary dictionary];
        recordLock = [[NSLock alloc] init];
        peripheralsByUUID = [NSMutableDictionary dictionary];
        peripheralLock = [[NSLock alloc] init];
        observedPeripheralIDs = [NSMutableSet set];
        jsContexts = [NSHashTable weakObjectsHashTable];
        YCYLoadRecords();
        NSLog(@"[YCYUnlock] State initialized v%@ frozen=%d records=%lu",
              kYCYVersion, gCanonicalFrozen, (unsigned long)canonicalWrites.count);
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
    if (bleLogs.count > 600) {
        [bleLogs removeObjectsInRange:NSMakeRange(0, bleLogs.count - 600)];
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

static NSString *YCYShortHex(NSData *data) {
    NSString *hex = YCYHexString(data);
    if (hex.length <= 24) return hex;
    return [[hex substringToIndex:23] stringByAppendingString:@"…"];
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
    if ([n containsString:@"WALKIZ"]) return YES;
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

static void YCYDumpInterestingClasses(void) {
    if (gDumpedClasses) return;
    gDumpedClasses = YES;
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (NSUInteger)n);
    n = objc_getClassList(classes, n);
    for (int i = 0; i < n; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if ([name localizedCaseInsensitiveContainsString:@"BLE"] ||
            [name localizedCaseInsensitiveContainsString:@"Bluetooth"] ||
            [name localizedCaseInsensitiveContainsString:@"DCBLE"] ||
            [name localizedCaseInsensitiveContainsString:@"Lock"] ||
            [name localizedCaseInsensitiveContainsString:@"JSEngine"] ||
            [name localizedCaseInsensitiveContainsString:@"JSContext"]) {
            if ([name hasPrefix:@"NS"] || [name hasPrefix:@"UI"] || [name hasPrefix:@"CB"]) continue;
            YCYLog(@"class %@", name);
        }
    }
    free(classes);
    Class dc = NSClassFromString(@"DCBLEManager");
    if (dc) {
        YCYLog(@"启动时发现 DCBLEManager");
        YCYDumpClassDetailed(dc);
    }
}

static void YCYDumpClassDetailed(Class cls) {
    if (!cls) return;
    YCYLog(@"==== dump %@ super=%@ ====",
           NSStringFromClass(cls),
           NSStringFromClass(class_getSuperclass(cls)));
    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        NSString *name = NSStringFromSelector(method_getName(ms[i]));
        if ([name hasPrefix:@"peripheral:"] ||
            [name hasPrefix:@"centralManager"] ||
            [name hasPrefix:@"."] ||
            [name isEqualToString:@"dealloc"]) {
            continue;
        }
        char *ret = method_copyReturnType(ms[i]);
        YCYLog(@"  - %@  args=%d ret=%s",
               name,
               method_getNumberOfArguments(ms[i]) - 2,
               ret ? ret : "?");
        if (ret) free(ret);
    }
    if (ms) free(ms);
    ms = class_copyMethodList(object_getClass((id)cls), &n);
    for (unsigned int i = 0; i < n; i++) {
        NSString *name = NSStringFromSelector(method_getName(ms[i]));
        if ([name hasPrefix:@"."] || [name isEqual:@"load"] || [name isEqual:@"initialize"] ||
            [name isEqual:@"alloc"] || [name hasPrefix:@"allocWith"]) continue;
        YCYLog(@"  + %@  args=%d", name, method_getNumberOfArguments(ms[i]) - 2);
    }
    if (ms) free(ms);
    Ivar *ivars = class_copyIvarList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        const char *nm = ivar_getName(ivars[i]);
        YCYLog(@"  ivar %s", nm ? nm : "?");
    }
    if (ivars) free(ivars);
}

static void YCYRememberDCBLE(id obj) {
    if (!obj) return;
    NSString *cls = NSStringFromClass([obj class]);
    if ([cls hasPrefix:@"YCY"]) return;
    if (![cls localizedCaseInsensitiveContainsString:@"BLE"] &&
        ![cls localizedCaseInsensitiveContainsString:@"Lock"]) {
        return;
    }
    gDCBLE = obj;
    if (!gDumpedDCBLE) {
        gDumpedDCBLE = YES;
        YCYLog(@"捕获 BLE 管理器 class=%@", cls);
        YCYDumpClassDetailed([obj class]);
        YCYDumpClassDetailed(object_getClass(obj));
    }
}

static BOOL YCYInvoke(id obj, NSString *selName, id arg) {
    if (!obj || selName.length == 0) return NO;
    SEL sel = NSSelectorFromString(selName);
    if (![obj respondsToSelector:sel]) return NO;
    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    if (!sig) return NO;
    NSUInteger nargs = sig.numberOfArguments;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    inv.target = obj;
    if (nargs >= 3) {
        const char *t = [sig getArgumentTypeAtIndex:2];
        if (t && t[0] == '@') {
            id a = arg;
            [inv setArgument:&a atIndex:2];
        } else if (t && (t[0] == 'i' || t[0] == 'q' || t[0] == 'l' || t[0] == 'B' || t[0] == 'Q' || t[0] == 'I')) {
            NSInteger v = 1;
            [inv setArgument:&v atIndex:2];
        } else {
            YCYLog(@"跳过 %@ 参数类型 %s", selName, t ? t : "?");
            return NO;
        }
    }
    YCYLog(@"invoke [%@ %@]", NSStringFromClass([obj class]), selName);
    @try {
        [inv invoke];
        return YES;
    } @catch (NSException *ex) {
        YCYLog(@"invoke 异常 %@: %@", selName, ex.reason);
        return NO;
    }
}

static BOOL YCYTryNativeOpen(void) {
    id mgr = gDCBLE;
    if (!mgr) {
        CBPeripheral *p = lastAppPeripheral;
        if (p.delegate) mgr = p.delegate;
    }
    if (!mgr) {
        Class cls = NSClassFromString(@"DCBLEManager");
        if (cls) {
            YCYDumpClassDetailed(cls);
            for (NSString *s in @[@"shared", @"sharedInstance", @"sharedManager", @"defaultManager", @"singleton"]) {
                if ([cls respondsToSelector:NSSelectorFromString(s)]) {
                    YCYLog(@"试 class 方法 +%@", s);
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    mgr = [cls performSelector:NSSelectorFromString(s)];
                    #pragma clang diagnostic pop
                    if (mgr) break;
                }
            }
        }
    }
    if (!mgr) {
        YCYLog(@"没有 DCBLEManager 实例");
        return NO;
    }
    YCYRememberDCBLE(mgr);

    NSArray *zeroArg = @[
        @"open", @"unlock", @"openLock", @"bleOpen", @"doOpen",
        @"sendOpen", @"unLock", @"bleUnlock", @"openBox",
        @"openDevice", @"unlockDevice", @"openAction", @"clickOpen"
    ];
    for (NSString *s in zeroArg) {
        if (YCYInvoke(mgr, s, nil)) return YES;
    }

    NSArray *oneArg = @[
        @"open:", @"unlock:", @"openLock:", @"bleOpen:", @"doOpen:",
        @"sendOpen:", @"bleUnlock:", @"_init_ble:", @"initBle:",
        @"ble_do:", @"bleDo:", @"sendCommand:", @"sendCmd:",
        @"writeCommand:", @"openWithType:", @"openType:",
        @"setAction:", @"doAction:", @"execute:", @"unlockWithMac:",
        @"openLockWithPeripheral:"
    ];
    NSArray *args = @[
        @"open",
        @{@"type": @"open", @"action": @"open", @"cmd": @"open"},
        @{@"command": @"open"},
        lastLockUUID.UUIDString ?: @"",
        lastAppPeripheral ?: @""
    ];
    for (NSString *s in oneArg) {
        for (id a in args) {
            if (YCYInvoke(mgr, s, a)) return YES;
        }
    }
    YCYLog(@"DCBLEManager 没有匹配到开锁方法，请看上面的 dump 列表");
    return NO;
}

static BOOL YCYConnectViaAppCentral(void) {
    if (!appCentral) {
        YCYLog(@"无 appCentral，无法让 App 自己重连");
        return NO;
    }
    if (appCentral.state != CBManagerStatePoweredOn) {
        YCYLog(@"appCentral state=%ld", (long)appCentral.state);
        return NO;
    }
    NSMutableArray *ids = [NSMutableArray array];
    if (lastLockUUID) [ids addObject:lastLockUUID];
    NSArray *known = ids.count ? [appCentral retrievePeripheralsWithIdentifiers:ids] : @[];
    YCYLog(@"appCentral retrieve count=%lu", (unsigned long)known.count);
    CBPeripheral *p = known.firstObject;
    if (!p) {
        NSArray *svcs = @[
            [CBUUID UUIDWithString:kYCYSvc9000],
            [CBUUID UUIDWithString:kYCYSvcAE00]
        ];
        NSArray *already = [appCentral retrieveConnectedPeripheralsWithServices:svcs];
        for (CBPeripheral *x in already) {
            if (YCYLooksLikeLockName(x.name)) { p = x; break; }
        }
        if (!p) p = already.firstObject;
    }
    if (p) {
        YCYRememberPeripheral(p);
        if (p.state == CBPeripheralStateConnected) {
            YCYLog(@"appCentral 外设已连接 %@", YCYPeripheralName(p));
            return YES;
        }
        YCYLog(@"appCentral 正在连接 %@（不抢 DCBLEManager）", YCYPeripheralName(p));
        YCYShowToast([NSString stringWithFormat:@"正在让 App 连接 %@", YCYPeripheralName(p)]);
        [appCentral connectPeripheral:p options:nil];
        return YES;
    }
    YCYLog(@"appCentral 扫描 YS04");
    YCYShowToast(@"正在让 App 搜索 YS04…");
    [appCentral scanForPeripheralsWithServices:nil
                                       options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
    return YES;
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

#pragma mark - 分类：唯一密文 vs 心跳

static void YCYReclassifyInPlace(NSMutableArray<YCYRecordedWrite *> *items) {
    for (YCYRecordedWrite *w in items) {
        if (w.seenCount >= 2) {
            w.heartbeatLike = YES;
            w.unlockLike = NO;
        } else if (!w.handshakeLike) {
            w.heartbeatLike = NO;
        }
        if (YCYLooksLikeUnlockPayload(w.value) || YCYLooksLikeStrongUnlock(w.value)) {
            w.unlockLike = YES;
            w.heartbeatLike = NO;
        }
    }
}

static NSArray<YCYRecordedWrite *> *YCYUniqueUnlockPackets(NSArray<YCYRecordedWrite *> *burst) {
    if (burst.count == 0) return @[];

    NSMutableArray *strong = [NSMutableArray array];
    for (YCYRecordedWrite *item in burst) {
        if (YCYLooksLikeStrongUnlock(item.value)) [strong addObject:item];
    }
    if (strong.count) return strong;

    NSMutableArray *unique = [NSMutableArray array];
    for (YCYRecordedWrite *item in burst) {
        if (item.handshakeLike) continue;
        if (item.heartbeatLike || item.seenCount >= 2) continue;
        [unique addObject:item];
    }
    if (unique.count == 0) return @[];

    YCYRecordedWrite *last = unique.lastObject;
    NSMutableArray *tail = [NSMutableArray array];
    for (YCYRecordedWrite *w in unique) {
        NSTimeInterval dt = last.time && w.time ? [last.time timeIntervalSinceDate:w.time] : 0;
        if (dt <= 0.85) [tail addObject:w];
    }
    return tail.count ? tail : unique;
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
        @"handshakeLike": @(item.handshakeLike),
        @"heartbeatLike": @(item.heartbeatLike),
        @"seenCount": @(item.seenCount),
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
    item.handshakeLike = [d[@"handshakeLike"] boolValue];
    item.heartbeatLike = [d[@"heartbeatLike"] boolValue];
    item.seenCount = [d[@"seenCount"] unsignedIntegerValue];
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
    if (arr.count == 0) {
        arr = [ud arrayForKey:kYCYRecordsKeyV2];
    }
    [canonicalWrites removeAllObjects];
    for (NSDictionary *d in arr) {
        YCYRecordedWrite *item = YCYWriteFromDict(d);
        if (item) [canonicalWrites addObject:item];
    }
    YCYReclassifyInPlace(canonicalWrites);
    BOOL hasFreq = NO;
    for (YCYRecordedWrite *w in canonicalWrites) {
        if (w.seenCount >= 1 || w.heartbeatLike) { hasFreq = YES; break; }
    }
    if (!hasFreq && canonicalWrites.count > 1) {
        NSLog(@"[YCYUnlock] 旧记录没有频率信息，已丢弃 %lu 条，请重新官方开锁一次",
              (unsigned long)canonicalWrites.count);
        [canonicalWrites removeAllObjects];
        gCanonicalFrozen = NO;
    } else {
        NSArray *unique = YCYUniqueUnlockPackets(canonicalWrites);
        if (unique.count > 0 && unique.count < canonicalWrites.count) {
            NSLog(@"[YCYUnlock] 加载后剔除心跳 %lu → 唯一 %lu",
                  (unsigned long)canonicalWrites.count, (unsigned long)unique.count);
            [canonicalWrites removeAllObjects];
            [canonicalWrites addObjectsFromArray:unique];
        }
        gCanonicalFrozen = [ud boolForKey:@"YCYUnlock.frozen"] && canonicalWrites.count > 0;
        if (canonicalWrites.count > 0 && unique.count > 0) {
            gCanonicalFrozen = YES;
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

static void YCYFreezeCanonicalFromSession(void) {
    [recordLock lock];
    YCYReclassifyInPlace(liveSession);
    NSArray *unique = YCYUniqueUnlockPackets(liveSession);
    BOOL didFreeze = NO;
    if (unique.count > 0) {
        [canonicalWrites removeAllObjects];
        [canonicalWrites addObjectsFromArray:unique];
        for (YCYRecordedWrite *w in canonicalWrites) {
            w.unlockLike = YES;
            w.heartbeatLike = NO;
        }
        gCanonicalFrozen = YES;
        didFreeze = YES;
        gFrozenSessionGen = gSessionGen;
        YCYLog(@"★ 冻结唯一开锁包 %lu 条（已丢弃心跳/重复，关锁不再覆盖）",
               (unsigned long)canonicalWrites.count);
        for (YCYRecordedWrite *w in canonicalWrites) {
            YCYLog(@"  冻结 HEX=%@", YCYHexString(w.value));
        }
    } else {
        YCYLog(@"冻结跳过：当前会话没有唯一密文（可能还没官方开锁） live=%lu",
               (unsigned long)liveSession.count);
    }
    [recordLock unlock];
    if (didFreeze) YCYPersistRecords();
}

static void YCYScheduleFreeze(void) {
    if (gCanonicalFrozen) return;
    if (gFreezeBlock) {
        dispatch_block_cancel(gFreezeBlock);
        gFreezeBlock = nil;
    }
    dispatch_block_t block = dispatch_block_create(0, ^{
        gFreezeBlock = nil;
        if (!gCanonicalFrozen) YCYFreezeCanonicalFromSession();
    });
    gFreezeBlock = block;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
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

    NSString *hex = YCYHexString(data);

    [recordLock lock];
    NSInteger seen = [payloadCounts[hex] integerValue] + 1;
    payloadCounts[hex] = @(seen);
    [recordLock unlock];

    if (gCanonicalFrozen) {
        YCYLog(@"已冻结，忽略写包 unique=%@ count=%ld HEX=%@",
               seen == 1 ? @"YES" : @"NO", (long)seen, hex);
        lastLockUUID = peripheral.identifier;
        lastLockName = YCYPeripheralName(peripheral);
        return;
    }

    BOOL handshakeSkip = NO;
    if (gHandshakeWritesLeft > 0) {
        gHandshakeWritesLeft--;
        handshakeSkip = YES;
    }
    if (gHandshakeUntil && [gHandshakeUntil timeIntervalSinceNow] > 0) {
        handshakeSkip = YES;
    }
    if (handshakeSkip) {
        YCYLog(@"握手包，跳过记录 left=%ld HEX=%@", (long)gHandshakeWritesLeft, hex);
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
    item.handshakeLike = NO;
    item.seenCount = (NSUInteger)seen;
    item.heartbeatLike = (seen >= 2);
    item.unlockLike = (!item.heartbeatLike);

    lastLockUUID = peripheral.identifier;
    lastLockName = item.peripheralName;

    [recordLock lock];
    YCYRecordedWrite *last = liveSession.lastObject;
    if (last && [item.time timeIntervalSinceDate:last.time] > 12.0) {
        [liveSession removeAllObjects];
    }
    BOOL dup = NO;
    if (liveSession.count > 0) {
        YCYRecordedWrite *prev = liveSession.lastObject;
        if ([prev.charUUID isEqualToString:item.charUUID] &&
            [prev.value isEqualToData:item.value]) {
            dup = YES;
            prev.seenCount = (NSUInteger)seen;
            prev.heartbeatLike = YES;
            prev.unlockLike = NO;
        }
    }
    if (!dup) {
        [liveSession addObject:item];
        if (liveSession.count > 20) {
            [liveSession removeObjectsInRange:NSMakeRange(0, liveSession.count - 20)];
        }
    }
    NSUInteger liveCount = liveSession.count;
    [recordLock unlock];

    YCYLog(@"★ 记录 %@ count=%ld live=%lu char=%@ HEX=%@",
           item.heartbeatLike ? @"心跳/重复" : @"唯一候选",
           (long)seen,
           (unsigned long)liveCount,
           charUUID,
           hex);

    if (!item.heartbeatLike) {
        YCYScheduleFreeze();
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
    NSArray<YCYRecordedWrite *> *packets = YCYUniqueUnlockPackets(burst);
    if (packets.count == 0) {
        YCYLog(@"重放取消：没有唯一开锁包（避免把心跳当开锁） recorded=%lu",
               (unsigned long)burst.count);
        YCYFinishUnlockFlight();
        return 0;
    }

    YCYLog(@"开始重放唯一包 packets=%lu / recorded=%lu needsRediscover=%d",
           (unsigned long)packets.count, (unsigned long)burst.count, gNeedsRediscover);
    for (YCYRecordedWrite *p in packets) {
        YCYLog(@"  将发送 HEX=%@", YCYHexString(p.value));
    }

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

    NSTimeInterval gap = 0.18;
    for (NSUInteger i = 0; i < packets.count; i++) {
        YCYRecordedWrite *item = packets[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * gap * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            sendOne(item);
        });
    }

    NSTimeInterval extraAt = packets.count * gap;
    if (packets.count == 1) {
        YCYRecordedWrite *only = packets.firstObject;
        extraAt += 0.28;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(extraAt * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            sendOne(only);
        });
    }

    NSTimeInterval total = extraAt + 0.6;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(total * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YCYLog(@"重放结束 sent≈%ld", (long)sent);
        YCYFinishUnlockFlight();
    });
    return (NSInteger)packets.count;
}

#pragma mark - JSContext（UniApp service 层）

static void YCYRememberJSContext(JSContext *ctx) {
    if (!ctx || gInJSProbe) return;
    YCYInitState();
    @synchronized (jsContexts) {
        [jsContexts addObject:ctx];
    }
    static BOOL probed = NO;
    if (probed) return;
    probed = YES;
    gInJSProbe = YES;
    @try {
        JSValue *v = [ctx evaluateScript:
            @"(function(){var a=[];function w(o,p,d){if(!o||d>3)return;try{var ks=Object.keys(o);for(var i=0;i<ks.length&&i<60;i++){var k=ks[i];if(/ble|open|lock|unlock|jm|ys0|dcble/i.test(k))a.push(p+k);var v=o[k];if(v&&typeof v==='object')w(v,p+k+'.',d+1);}}catch(e){}}"
            "try{if(typeof _ble_do==='function')a.push('_ble_do');"
            "if(typeof _init_ble==='function')a.push('_init_ble');"
            "if(typeof plus!=='undefined'){a.push('plus');w(plus,'plus.',2);}"
            "if(typeof uni!=='undefined'){a.push('uni');w(uni,'uni.',2);}"
            "if(typeof weex!=='undefined')a.push('weex');"
            "if(typeof getApp==='function'){a.push('getApp');try{w(getApp(),'app.',2);}catch(e){}}"
            "}catch(e){}return a.slice(0,40).join(',')||'none';})()"];
        YCYLog(@"JSContext probe globals=%@", v.isString ? v.toString : @"?");
    } @catch (NSException *ex) {
        YCYLog(@"JS probe 异常: %@", ex.reason);
    }
    gInJSProbe = NO;
}

static BOOL YCYTryJSOpen(void) {
    NSArray *ctxs;
    @synchronized (jsContexts) {
        ctxs = [[jsContexts allObjects] copy];
    }
    if (ctxs.count == 0) {
        YCYLog(@"无 JSContext，跳过 App 内部开锁");
        return NO;
    }
    NSString *script =
        @"(function(){try{"
        "if(typeof _ble_do==='function'){_ble_do('open');return 'opened:_ble_do';}"
        "if(typeof _init_ble==='function'){_init_ble('open');return 'opened:_init_ble';}"
        "if(typeof uni!=='undefined'&&uni.$emit){uni.$emit('ycy-force-open');return 'opened:uni.emit';}"
        "return 'miss';"
        "}catch(e){return 'err:'+String(e);}})()";
    gInJSProbe = YES;
    BOOL opened = NO;
    for (JSContext *ctx in ctxs) {
        @try {
            JSValue *v = [ctx evaluateScript:script];
            NSString *s = v.isString ? v.toString : @"nil";
            YCYLog(@"JS open result=%@", s);
            if ([s hasPrefix:@"opened:"]) opened = YES;
        } @catch (NSException *ex) {
            YCYLog(@"JS open 异常: %@", ex.reason);
        }
    }
    gInJSProbe = NO;
    return opened;
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
    if (n <= 0) {
        YCYShowToast(@"已连接，但没有唯一开锁包\n请先官方开锁一次");
    } else {
        YCYShowToast([NSString stringWithFormat:@"已连接，正在重放 %ld 条唯一指令", (long)n]);
    }
}

- (BOOL)hasWriteChars:(CBPeripheral *)p {
    return YCYWriteCharacteristics(p).count > 0;
}

- (void)discoverOn:(CBPeripheral *)peripheral {
    self.target = peripheral;
    peripheral.delegate = self;
    YCYLog(@"开始发现服务（强制刷新） %@", YCYPeripheralName(peripheral));
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
    if (n <= 0) {
        YCYShowToast(@"没有唯一开锁包\n请先让控方同意并成功开锁一次");
    } else {
        YCYShowToast([NSString stringWithFormat:@"正在重放 %ld 条唯一指令", (long)n]);
    }
}

static void YCYTryUnlockWithBurst(NSArray *burst, BOOL tryJS) {
    YCYInitState();
    if (gUnlockInFlight) {
        YCYShowToast(@"正在开锁，请稍候");
        return;
    }

    NSArray *connected = YCYConnectedPeripherals();
    CBPeripheral *ready = YCYPickPeripheral(connected, lastLockUUID);
    BOOL appConnected = ready && ready.state == CBPeripheralStateConnected;

    // 修复1：只要未重新产生断开/重新发现标识且世代未变，同连接会话内部即认为有效
    BOOL sameSession = appConnected && !gNeedsRediscover
        && (gFrozenSessionGen == 0 || gFrozenSessionGen == gSessionGen);

    YCYLog(@"尝试开锁 connected=%lu sameSession=%d frozen=%d js=%d native=%@ session=%lu/%lu",
           (unsigned long)connected.count,
           sameSession,
           gCanonicalFrozen,
           tryJS,
           gDCBLE ? NSStringFromClass([gDCBLE class]) : @"nil",
           (unsigned long)gFrozenSessionGen,
           (unsigned long)gSessionGen);

    gUnlockInFlight = YES;
    YCYSetButtonBusy(YES);

    // 1) 原生 DCBLEManager：如果已连接且握手结束，优先让 App 用当前会话密钥组包
    if (appConnected && gHandshakeWritesLeft <= 0 && YCYTryNativeOpen()) {
        YCYShowToast(@"已调用 DCBLEManager 开锁");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YCYFinishUnlockFlight();
        });
        return;
    }

    // 2) JS 兜底
    if (appConnected && gHandshakeWritesLeft <= 0 && tryJS && YCYTryJSOpen()) {
        YCYShowToast(@"已调用 App 内部 JS 开锁");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YCYFinishUnlockFlight();
        });
        return;
    }

    // 3) 未连接或断电状态：走 App 的 CBCentralManager 重连
    if (!appConnected) {
        YCYLog(@"未连接，走 appCentral 重连（禁止盲放旧密文）");
        BOOL started = YCYConnectViaAppCentral();
        if (started) {
            YCYShowToast(@"锁盒已断电或断连\n正在让 App 重连并自动开锁...");

            // 修复2：采用状态轮询检测替代死板延时，等待 App 重新完成握手并发送新的 Challenge 包
            __block int attempts = 0;
            __block void (^retryBlock)(void) = nil;
            __block __weak void (^weakRetry)(void) = nil;
            retryBlock = ^{
                attempts++;
                BOOL isReady = (lastAppPeripheral.state == CBPeripheralStateConnected);
                BOOL handshakeDone = (gHandshakeWritesLeft <= 0);

                if (isReady && handshakeDone) {
                    if (YCYTryNativeOpen()) {
                        YCYShowToast(@"握手完成，已调用 DCBLEManager 开锁");
                        YCYFinishUnlockFlight();
                        return;
                    } else if (tryJS && YCYTryJSOpen()) {
                        YCYShowToast(@"握手完成，已调用 JS 开锁");
                        YCYFinishUnlockFlight();
                        return;
                    }
                }

                if (attempts < 7) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), weakRetry);
                } else {
                    YCYShowToast(@"重连/握手超时，尝试强制发送指令...");
                    if (YCYTryNativeOpen()) {
                        YCYShowToast(@"已强制触发 DCBLEManager");
                    } else {
                        YCYShowToast(@"未能触发原生开锁，请看日志 dump");
                    }
                    YCYFinishUnlockFlight();
                }
            };
            weakRetry = retryBlock;

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), retryBlock);
            return;
        }
        YCYFinishUnlockFlight();
        YCYShowToast(@"无法让 App 重连\n请先打开 App 蓝牙页再试");
        return;
    }

    // 4) 仍是同一会话才允许重放旧密文
    if (!sameSession) {
        YCYLog(@"会话已变，拒绝重放旧密文 needsRediscover=%d", gNeedsRediscover);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (YCYTryNativeOpen()) {
                YCYShowToast(@"新会话已调用原生指令开锁");
            } else {
                YCYShowToast(@"当前是新连接，旧密文失效\n原生没匹配到方法，请发日志");
            }
            YCYFinishUnlockFlight();
        });
        return;
    }

    if (!gCanonicalFrozen) {
        YCYFreezeCanonicalFromSession();
    }
    NSArray *effective = burst;
    if (effective.count == 0) {
        effective = YCYUniqueUnlockPackets(YCYCanonicalCopy());
    } else {
        NSArray *filtered = YCYUniqueUnlockPackets(effective);
        if (filtered.count) effective = filtered;
    }
    if (effective.count == 0) {
        YCYFinishUnlockFlight();
        YCYShowToast(@"同一会话内也没有可重放的包\n请确认已由控方正常开锁过");
        return;
    }
    YCYDoReplay(effective, ready);
}

static void YCYTryUnlock(void) {
    YCYTryUnlockWithBurst(nil, YES);
}

#pragma mark - 日志 / 记录 UI

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
        NSArray *unique = YCYUniqueUnlockPackets(all);
        NSMutableString *text = [NSMutableString string];
        if (all.count == 0) {
            [text appendString:@"暂无已记录的开锁指令\n请先让控方正常同意并成功开锁一次\n插件只会保存「只出现一次」的密文，心跳会被丢掉"];
        } else {
            [text appendFormat:@"状态：%@\n唯一包：%lu  原始：%lu\n\n",
             gCanonicalFrozen ? @"已冻结（只重放唯一包）" : @"采集中",
             (unsigned long)unique.count,
             (unsigned long)all.count];
            NSInteger i = 1;
            for (YCYRecordedWrite *item in unique.count ? unique : all) {
                [text appendFormat:@"%ld. %@ %@\n%@\n\n",
                 (long)i++,
                 item.heartbeatLike ? @"[心跳]" : @"[唯一]",
                 item.peripheralName,
                 YCYHexString(item.value)];
            }
        }

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"已记录的唯一开锁包"
                                                message:text
                                         preferredStyle:UIAlertControllerStyleAlert];

        NSInteger idx = 0;
        for (YCYRecordedWrite *item in unique) {
            if (idx >= 4) break;
            NSString *title = [NSString stringWithFormat:@"重放第 %ld 条 %@",
                               (long)(idx + 1), YCYShortHex(item.value)];
            YCYRecordedWrite *captured = item;
            [alert addAction:[UIAlertAction actionWithTitle:title
                                                      style:UIAlertActionStyleDestructive
                                                    handler:^(UIAlertAction *a) {
                (void)a;
                YCYTryUnlockWithBurst(@[captured], NO);
            }]];
            idx++;
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"关闭"
                                                  style:UIAlertActionStyleCancel
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
    [payloadCounts removeAllObjects];
    gCanonicalFrozen = NO;
    [recordLock unlock];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud removeObjectForKey:kYCYRecordsKey];
    [ud removeObjectForKey:kYCYRecordsKeyV2];
    [ud setBool:NO forKey:@"YCYUnlock.frozen"];
    [ud synchronize];
    YCYLog(@"Records cleared — 等待下一次官方开锁以捕获唯一包");
    YCYShowToast(@"已清空。请让控方再开锁一次\n插件只会保存唯一密文");
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
    NSArray *unique = YCYUniqueUnlockPackets(canon);
    NSString *msg = [NSString stringWithFormat:
        @"短按：开锁（原生优先 / 自动重连）\n长按：本菜单\nv%@  监控：%@\n唯一包：%lu  原始：%lu%@\n已连接：%lu",
        kYCYVersion,
        monitorEnabled ? @"开" : @"关",
        (unsigned long)unique.count,
        (unsigned long)canon.count,
        gCanonicalFrozen ? @"（已冻结）" : @"",
        (unsigned long)YCYConnectedPeripherals().count];

    UIAlertController *menu =
        [UIAlertController alertControllerWithTitle:@"YCY Unlock"
                                            message:msg
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    [menu addAction:[UIAlertAction actionWithTitle:@"仅调用 DCBLEManager 开锁"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *a) {
                                               (void)a;
                                               if (YCYTryNativeOpen()) {
                                                   YCYShowToast(@"已调用 DCBLEManager");
                                               } else {
                                                   YCYShowToast(@"没匹配到方法，请复制日志");
                                               }
                                           }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"仅重放唯一 BLE 包"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
                                               (void)a;
                                               YCYTryUnlockWithBurst(nil, NO);
                                           }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"仅触发 App 内部开锁"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
                                               (void)a;
                                               if (YCYTryJSOpen()) {
                                                   YCYShowToast(@"已调用 App 内部开锁接口");
                                               } else {
                                                   YCYShowToast(@"没找到 _ble_do，请看日志里的 JS probe");
                                               }
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
    [menu addAction:[UIAlertAction actionWithTitle:@"重新捕获（清空后等官方开锁）"
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
        gSessionGen += 1;
        gHandshakeWritesLeft = 3;
        gHandshakeUntil = [NSDate dateWithTimeIntervalSinceNow:6.0];
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
    gSessionGen += 1;
    gHandshakeWritesLeft = 3;
    gHandshakeUntil = [NSDate dateWithTimeIntervalSinceNow:6.0];
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
    if (delegate) YCYRememberDCBLE(delegate);
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

#pragma mark - JSContext

%hook JSContext

- (JSValue *)evaluateScript:(NSString *)script {
    YCYRememberJSContext(self);
    return %orig;
}

- (JSValue *)evaluateScript:(NSString *)script withSourceURL:(NSURL *)sourceURL {
    YCYRememberJSContext(self);
    return %orig;
}

%end

#pragma mark - App 生命周期

%hook UIApplication

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    YCYInitState();
    YCYLog(@"didFinishLaunching");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YCYDumpInterestingClasses();
    });
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
    YCYLog(@"YCYUnlock loaded v%@", kYCYVersion);
    YCYLog(@"断电后禁止盲放旧密文，自动通过 appCentral 重连并触发 DCBLEManager");
    YCYLog(@"短按 = 原生开锁 / 状态检测重连");
    YCYLog(@"长按 = 菜单 / dump");
    YCYLog(@"==============================");
    YCYScheduleFloatingButton();
}
#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <QuartzCore/QuartzCore.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <objc/runtime.h>

/*
* YCYUnlock v1.3.1（断电重连修复版）
*
* 日志结论（断电失败）：
* - 握手是：WRITE 13 35…（跨会话不变）→ NOTIFY Challenge → WRITE 4B 58… + 9B 17…（会话密文）
* - v1.2 掌握手后两包冻成「开锁」，同连接重放能收到通知；断电后挑战变了，旧密文被锁忽略（无 NOTIFY）
* - JS _ble_do 不是全局（miss）；最初的类是 DCBLEManager
*
* v1.3.1 修复：
* 1. 增加 DCBLEManager 的补偿方法契约与入参，提高命中率。
* 2.精准判断同会话（删除死板的15秒空闲拦截）。
* 3.断​​电重连加入基于握手标志位（gHandshakeWritesLeft）的状态轮询检测，完成新挑战后自动开锁。
*/

# pragma mark - 常量（YS04 / Walkiz）

static NSString * const kYCYChar9001 = @"00009001-0000-1000-8000-57616C6B697A" ;
static NSString * const kYCYCharAE01 = @"AE01" ;
static NSString * const kYCYSvc9000 = @"00009000-0000-1000-8000-57616C6B697A" ;
static NSString * const kYCYSvcAE00 = @"AE00" ;
static NSString * const kYCYRecordsKey = @"YCYUnlock.canonicalWrites.v3" ;
static NSString * const kYCYRecordsKeyV2 = @"YCYUnlock.canonicalWrites.v2" ;
静态 NSString * const kYCYLockUUIDKey = @"YCYUnlock.lastLockUUID" ;
static NSString * const kYCYLockNameKey = @"YCYUnlock.lastLockName" ;
static NSString * const kYCYVersion = @"1.3.1" ;

# pragma mark - 全局

static UIWindow *floatWindow;
static UIButton *floatButton;
static UILabel *toastLabel;

static NSMutableArray < NSString *> *bleLogs;
static NSLock *bleLogLock;

static BOOL monitorEnabled = YES ;
static BOOL gIgnoreHookWrite = NO ;
static BOOL gUnlockInFlight = NO ;
static BOOL gCanonicalFrozen = NO ;
static BOOL gNeedsRediscover = NO ;
static BOOL gInJSProbe = NO ;
static BOOL gDumpedClasses = NO ;
static BOOL gDumpedDCBLE = NO ;
static NSDate *gHandshakeUntil;
static NSInteger gHandshakeWritesLeft = 0 ;
static NSUInteger gSessionGen = 0 ;
static NSUInteger gFrozenSessionGen = 0 ;

static NSMutableDictionary < NSString *, CBPeripheral *> *peripheralsByUUID;
static NSLock *peripheralLock;
static CBCentralManager *appCentral;
静态 NSUUID *lastLockUUID;
static NSString *lastLockName;
static __ weak CBPeripheral *lastAppPeripheral;
静态 __ 弱标识符 gDCBLE；
static NSDate *lastAppWriteTime;
static NSMutableSet < NSString *> *observedPeripheralIDs;
static NSHashTable *jsContexts;

@interface YCYRecordedWrite : NSObject
@property ( nonatomic , copy ) NSUUID *外设 ID;
@property ( nonatomic , copy ) NSString *peripheralName;
@property ( nonatomic , copy ) NSString *serviceUUID;
@property ( nonatomic , copy ) NSString *charUUID;
@property ( nonatomic , copy ) NSData *value;
@property ( nonatomic , assign ) CBCharacteristicWriteType 类型;
@property ( nonatomic , strong ) NSDate *time;
@property ( nonatomic , assign ) BOOL unlockLike;
@property ( nonatomic , assign ) BOOL handshakeLike;
@property ( nonatomic , assign ) BOOL heartbeatLike;
@property ( nonatomic , assign ) NSUInteger seenCount;
@结尾

@implementation YCYRecordedWrite
@结尾

static NSMutableArray *canonicalWrites;
static NSMutableArray *liveSession;
static NSMutableDictionary < NSString *, NSNumber *> *payloadCounts;
static NSLock *recordLock;
static dispatch_block_t gFreezeBlock;

# 杂注标记 - 工具

static void YCYPersistRecords( void );
static void YCYLoadRecords( void );
static void YCYScheduleFloatingButton( void );
static NSArray *YCYUniqueUnlockPackets( NSArray *burst);
static void YCYReclassifyInPlace( NSMutableArray *items);
static void YCYDumpClassDetailed(Class cls);
static void YCYShowToast( NSString *text);
static void YCYRememberPeripheral(CBPeripheral *peripheral);

static void YCYInitState( void ) {
static dispatch_once_t onceToken;
dispatch_once (&onceToken, ^{
bleLogs = [ NSMutableArray 数组];
bleLogLock = [[ NSLock alloc] init];
canonicalWrites = [ NSMutableArray 数组];
liveSession = [ NSMutableArray 数组];
payloadCounts = [ NSMutableDictionary dictionary];
recordLock = [[ NSLock alloc] init];
peripheralsByUUID = [ NSMutableDictionary dictionary];
peripheralLock = [[ NSLock alloc] init];
observedPeripheralIDs = [ NSMutableSet set];
jsContexts = [ NSHashTable weakObjectsHashTable];
YCYLoadRecords();
NSLog ( @"[YCYUnlock] 状态已初始化 v%@ frozen=%d records=%lu" ,
kYCYVersion、gCanonicalFrozen、（ 无符号长整型 ）canonicalWrites.count）；
});
}

static void YCYLog( NSString *format, ...) {
YCYInitState();
va_list 参数；
va_start(args, format);
NSString *message = [[ NSString alloc] initWithFormat:format arguments:args];
va_end(args);

NSString *line = [ NSString stringWithFormat: @"[YCYUnlock] %@" , message];
NSLog ( @"%@" , line);

[bleLogLock 锁定]；
[bleLogs addObject:line];
如果 (bleLogs.count > 600 ) {
[bleLogs removeObjectsInRange: NSMakeRange ( 0 , bleLogs.count - 600 )];
}
[bleLogLock 解锁]；
}

static NSString *YCYHexString( NSData *data) {
如果 (!data || data.length == 0 ) 返回 @"<empty>" ;
const unsigned char *bytes = data.bytes;
NSMutableString *result = [ NSMutableString string];
for ( NSUInteger i = 0 ; i < data.length; i++) {
[result appendFormat: @"%02X" , bytes[i]];
if (i + 1 < data.length) [result appendString: @" " ];
}
返回结果；
}

static NSString *YCYShortHex( NSData *data) {
NSString *hex = YCYHexString(data);
如果 (hex.length <= 24 ) 返回 hex；
返回 [[hex substringToIndex: 23 ] stringByAppendingString: @"…" ];
}

static NSString *YCYUUIDString( NSUUID *uuid) {
返回 uuid.UUIDString ?: @"<nil>" ;
}

static NSString *YCYPeripheralName(CBPeripheral *peripheral) {
如果 (!外设) 返回 @"<nil>" ;
返回 peripheral.name.length ? peripheral.name : @"<Unnamed>" ;
}

static NSString *YCYNormUUID( id uuidObj) {
NSString *s = nil ;
如果 ([uuidObj isKindOfClass:[CBUUID class ]]) {
s = [(CBUUID *)uuidObj UUIDString];
} else if ([uuidObj isKindOfClass:[ NSString class ]]) {
s = ( NSString *)uuidObj;
} else if ([uuidObj isKindOfClass:[ NSUUID 类 ]]) {
s = [( NSUUID *)uuidObj UUIDString];
}
返回 s.uppercaseString ?: @"" ;
}

static BOOL YCYUUIDMatch( NSString *a, NSString *b) {
NSString *x = YCYNormUUID(a);
NSString *y = YCYNormUUID(b);
如果 (x.length == 0 || y.length == 0 ) 返回 NO ；
如果 ([x isEqualToString:y]) 返回 YES ;
NSString *shortX = x;
NSString *shortY = y;
如果 (x.length == 36 && [x hasPrefix: @"0000" ] && [x hasSuffix: @"-0000-1000-8000-00805F9B34FB" ]) {
shortX = [x substringWithRange: NSMakeRange ( 4 , 4 )];
}
如果 (y.length == 36 && [y hasPrefix: @"0000" ] && [y hasSuffix: @"-0000-1000-8000-00805F9B34FB" ]) {
shortY = [y substringWithRange: NSMakeRange ( 4 , 4 )];
}
如果 (x.length == 4 ) shortX = x;
如果 (y.length == 4 ) shortY = y;
返回 [shortX isEqualToString:shortY];
}

static BOOL YCYIsTargetCharacteristic( NSString *uuid) {
NSString *u = YCYNormUUID(uuid);
如果 (u.length == 0 ) 返回 NO ；
如果 (YCYUUIDMatch(u, kYCYChar9001)) 返回 YES ；
如果 (YCYUUIDMatch(u, kYCYCharAE01)) 返回 YES ；
如果 ([u containsString: @"9001" ]) 返回 YES ;
如果 ([u containsString: @"AE01" ]) 返回 YES ;
返回 NO ；
}

static BOOL YCYLooksLikeStrongUnlock( NSData *data) {
如果 (!data || data.length < 3 ) 返回 NO ;
const unsigned char *b = data.bytes;
如果 (data.length >= 3 && b[ 0 ] == 0x05 && b[ 1 ] == 0x01 && b[ 2 ] == 0x06 ) 返回 YES ;
如果 (data.length >= 4 && b[ 0 ] == 0x06 && b[ 1 ] == 0x01 && b[ 2 ] == 0x01 && b[ 3 ] == 0x01 ) 返回 YES ;
如果 (data.length >= 4 && b[ 0 ] == 0xAF && b[ 1 ] == 0x0F && (b[ 2 ] == 0xC0 || b[ 2 ] == 0xD0 )) 返回 YES ;
如果 (data.length >= 3 && b[ 0 ] == 0xAA && b[ 1 ] == 0x55 ) 返回 YES ;
返回 NO ；
}

static BOOL YCYLooksLikeUnlockPayload( NSData *data) {
如果 (!data || data.length < 2 ) 返回 NO ;
如果 (YCYLooksLikeStrongUnlock(data)) 返回 YES ；
const unsigned char *b = data.bytes;
如果 (b[ 0 ] == 0x01 && b[ 1 ] == 0x00 ) 返回 YES ；
如果 (b[ 0 ] == 0x20 && b[ 1 ] == 0x01 ) 返回 YES ；
返回 NO ；
}

static BOOL YCYLooksLikeLockName( NSString *name) {
如果 (name.length == 0 ) 返回 NO ；
NSString *n = name.uppercaseString;
如果 ([n 包含字符串: @"YS04" ]) 返回 YES ;
如果 ([n 包含字符串: @"YS0" ]) 返回 YES ;
如果 ([n 包含字符串: @"YISKJ" ]) 返回 YES ;
如果 ([n containsString: @"WALKIZ" ]) 返回 YES ;
返回 NO ；
}

static NSString *YCYProperties(CBCharacteristic *characteristic) {
CBCharacteristicProperties p = characteristic.properties;
NSMutableArray *items = [ NSMutableArray 数组];
如果 (p & CBCharacteristicPropertyBroadcast) [items addObject: @"Broadcast" ];
如果 (p & CBCharacteristicPropertyRead) [items addObject: @"Read" ];
如果 (p & CBCharacteristicPropertyWriteWithoutResponse) [items addObject: @"WriteWithoutResponse" ];
如果 (p & CBCharacteristicPropertyWrite) [items addObject: @"Write" ];
如果 (p & CBCharacteristicPropertyNotify) [items addObject: @"Notify" ];
如果 (p & CBCharacteristicPropertyIndi​​cate) [items addObject: @"Indicate" ];
返回 items.count ? [items componentsJoinedByString: @" | " ] : @"None" ;
}

static void YCYDumpInterestingClasses( void ) {
如果 (gDumpedClasses) 返回 ；
gDumpedClasses = YES ；
int n = objc_getClassList( NULL , 0 );
如果 (n <= 0 ) 返回 ；
Class *classes = (Class *)malloc( sizeof (Class) * ( NSUInteger )n);
n = objc_getClassList(classes, n);
for ( int i = 0 ; i < n; i++) {
NSString *name = NSStringFromClass (classes[i]);
如果 （[name localizedCaseInsensitiveContainsString: @"BLE" ] ||
[name localizedCaseInsensitiveContainsString: @"Bluetooth" ] ||
[name localizedCaseInsensitiveContainsString: @"DCBLE" ] ||
[name localizedCaseInsensitiveContainsString: @"Lock" ] ||
[name localizedCaseInsensitiveContainsString: @"JSEngine" ] ||
[name localizedCaseInsensitiveContainsString: @"JSContext" ]) {
如果 ([name hasPrefix: @"NS" ] || [name hasPrefix: @"UI" ] || [name hasPrefix: @"CB" ]) continue ;
YCYLog( @"class %@" , name);
}
}
免费（课程）；
Class dc = NSClassFromString ( @"DCBLEManager" );
如果 (dc) {
YCYLog( @"启动时发现 DCBLEManager" );
YCYDumpClassDetailed(dc);
}
}

static void YCYDumpClassDetailed(Class cls) {
如果 (!cls) 返回 ；
YCYLog( @"==== dump %@ super=%@ ====" ,
NSStringFromClass (cls)
NSStringFromClass (class_getSuperclass(cls)));
unsigned int n = 0 ;
方法 *ms = class_copyMethodList(cls, &n);
for ( unsigned int i = 0 ; i < n; i++) {
NSString *name = NSStringFromSelector (method_getName(ms[i]));
如果 （[name hasPrefix: @"peripheral:" ] ||
[name hasPrefix: @"centralManager" ] ||
[名称前缀： @"." ] ||
[name isEqualToString: @"dealloc" ]) {
继续 ;
}
char *ret = method_copyReturnType(ms[i]);
YCYLog( @" - %@ args=%d ret=%s" ,
姓名，
method_getNumberOfArguments(ms[i]) - 2 ,
ret ? ret : "？" );
如果 (ret) 释放(ret)；
}
如果 (ms) 空闲(ms)；
ms = class_copyMethodList(object_getClass(( id )cls), &n);
for ( unsigned int i = 0 ; i < n; i++) {
NSString *name = NSStringFromSelector (method_getName(ms[i]));
如果 ([name hasPrefix: @"." ] || [name isEqual: @"load" ] || [name isEqual: @"initialize" ] ||
[name isEqual: @"alloc" ] || [name hasPrefix: @"allocWith" ]) continue ;
YCYLog( @" + %@ args=%d" , name, method_getNumberOfArguments(ms[i]) - 2 );
}
如果 (ms) 空闲(ms)；
Ivar *ivars = class_copyIvarList(cls, &n);
for ( unsigned int i = 0 ; i < n; i++) {
const char *nm = ivar_getName(ivars[i]);
YCYLog( @" ivar %s" , nm ? nm : "?" );
}
如果 (ivars) free(ivars);
}

static void YCYRememberDCBLE( id obj) {
如果 (!obj) 返回 ；
NSString *cls = NSStringFromClass ([obj class ]);
如果 （[cls hasPrefix: @"YCY" ]） 返回 ；
如果 (![cls localizedCaseInsensitiveContainsString: @"BLE" ] &&
![cls localizedCaseInsensitiveContainsString: @"Lock" ]) {
返回 ;
}
gDCBLE = obj;
如果 (!gDumpedDCBLE) {
gDumpedDCBLE = 是 ；
YCYLog( @"捕获 BLE 管理器 class=%@" , cls);
YCYDumpClassDetailed([对象类 ]);
YCYDumpClassDetailed(object_getClass(obj));
}
}

static BOOL YCYInvoke( id obj, NSString *selName, id arg) {
如果 (!obj || selName.length == 0 ) 返回 NO ；
SEL sel = NSSelectorFromString (selName);
如果 (![obj respondsToSelector:sel]) 返回 NO ;
NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
如果 (!sig) 返回 NO ；
NSUInteger nargs = sig.numberOfArguments;
NSInvocation *inv = [ NSInvocation invocationWithMethodSignature:sig];
inv.selector = sel;
inv.target = obj;
如果 (nargs >= 3 ) {
const char *t = [sig getArgumentTypeAtIndex: 2 ];
如果 (t && t[ 0 ] == '@' ) {
id a = arg;
[inv setArgument:&a atIndex: 2 ];
} else if (t && (t[ 0 ] == 'i' || t[ 0 ] == 'q' || t[ 0 ] == 'l' || t[ 0 ] == 'B' || t[ 0 ] == 'Q' || t[ 0 ] == 'I' )) {
NSInteger v = 1 ；
[inv setArgument:&v atIndex: 2 ];
} 别的 {
YCYLog( @" 跳过 %@ 参数类型 %s" , selName, t ? t : "?" );
返回 NO ；
}
}
YCYLog( @"调用 [%@ %@]" , NSStringFromClass ([obj class ]), selName);
@尝试 {
[inv invoke];
返回 YES ；
} @catch ( NSException *ex) {
YCYLog( @"调用异常 %@: %@" , selName, ex.reason);
返回 NO ；
}
}

static BOOL YCYTryNativeOpen( void ) {
id mgr = gDCBLE;
如果 (!mgr) {
CBPeripheral *p = lastAppPeripheral;
如果 (p.delegate) mgr = p.delegate;
}
如果 (!mgr) {
Class cls = NSClassFromString ( @"DCBLEManager" );
如果 (cls) {
YCYDumpClassDetailed(cls);
for ( NSString *s in @[ @"shared" , @"sharedInstance" , @"sharedManager" , @"defaultManager" , @"singleton" ]) {
如果 ([cls respondsToSelector: NSSelectorFromString (s)]) {
YCYLog( @"试类方法 +%@" , s);
# pragma clang 诊断推送
# pragma clang diagnostic ignored "-Warc-performSelector-leaks"
mgr = [cls performSelector: NSSelectorFromString (s)];
# pragma clang 诊断弹出
如果 (mgr) 则跳出 ；
}
}
}
}
如果 (!mgr) {
YCYLog( @"没有 DCBLEManager 实例" );
返回 NO ；
}
YCYRememberDCBLE(mgr);

NSArray *zeroArg = @[
@"open" , @"unlock" , @"openLock" , @"bleOpen" , @"doOpen" ,
@"sendOpen" , @"unLock" , @"bleUnlock" , @"openBox" ,
@“openDevice” ， @“unlockDevice” ， @“openAction” ， @“clickOpen”
];
for ( NSString *s in zeroArg) {
如果 (YCYInvoke(mgr, s, nil )) 返回 YES ；
}

NSArray *oneArg = @[
@"open:" , @"unlock:" , @"openLock:" , @"bleOpen:" , @"doOpen:" ,
@"sendOpen:" , @"bleUnlock:" , @"_init_ble:" , @"initBle:" ,
@“ble_do：” ， @“bleDo：” ， @“sendCommand：” ， @“sendCmd：” ，
@"writeCommand:" , @"openWithType:" , @"openType:" ,
@"setAction:" , @"doAction:" , @"execute:" , @"unlockWithMac:" ,
@"openLockWithPeripheral:"
];
NSArray *args = @[
@“打开” ，
@{ @"type" : @"open" , @"action" : @"open" , @"cmd" : @"open" },
@{ @"command" : @"open" },
lastLockUUID.UUIDString ?: @"" ,
lastAppPeripheral ?: @""
];
for ( NSString *s in oneArg) {
for ( id a in args) {
如果 (YCYInvoke(mgr, s, a)) 返回 YES ；
}
}
YCYLog( @"DCBLEManager 没有匹配到开锁方法，请看上面的转储列表" );
返回 NO ；
}

static BOOL YCYConnectViaAppCentral( void ) {
如果 (!appCentral) {
YCYLog( @"无 appCentral，无法让 App 自己重连" );
返回 NO ；
}
如果 (appCentral.state != CBManagerStatePoweredOn) {
YCYLog( @"appCentral state=%ld" , ( long )appCentral.state);
返回 NO ；
}
NSMutableArray *ids = [ NSMutableArray 数组];
if (lastLockUUID) [ids addObject:lastLockUUID];
NSArray *known = ids.count ? [appCentral retrievePeripheralsWithIdentifiers:ids] : @[];
YCYLog( @"appCentral 检索计数=%lu" , ( unsigned long )known.count);
CBPeripheral *p = known.firstObject;
如果 (!p) {
NSArray *svcs = @[
[CBUUID UUIDWithString:kYCYSvc9000],
[CBUUID UUIDWithString:kYCYSvcAE00]
];
NSArray *already = [appCentral retrieveConnectedPeripheralsWithServices:svcs];
for (CBPeripheral *x in already) {
如果 (YCYLooksLikeLockName(x.name)) { p = x; break ; }
}
如果 (!p) p = already.firstObject;
}
如果 (p) {
YCYRememberPeripheral(p);
如果 (p.state == CBPeripheralStateConnected) {
YCYLog( @"appCentral 外设已连接 %@" , YCYPeripheralName(p));
返回 YES ；
}
YCYLog( @"appCentral 正在连接 %@（不抢 DCBLEManager）" , YCYPeripheralName(p));
YCYShowToast([ NSString stringWithFormat: @"正在让 App 连接 %@" , YCYPeripheralName(p)]);
[appCentral connectPeripheral:p options: nil ];
返回 YES ；
}
YCYLog( @"appCentral 扫描 YS04" );
YCYShowToast( @"正在让应用搜索 YS04…" );
[appCentral scanForPeripheralsWithServices: nil
options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
返回 YES ；
}

# pragma mark - 外设池

static void *kYCYStateObs = &kYCYStateObs;

@interface YCYUnlockHelper : NSObject
+（ 实例类型 ）共享；
- ( void )onTap;
- ( void )onLongPress:( UILongPressGestureRecognizer *)g;
- ( void )onPan:( UIPanGestureRecognizer *)g;
@结尾

static void YCYRememberPeripheral(CBPeripheral *peripheral) {
如果 （!外设） 返回 ；
NSString *key = peripheral.identifier.UUIDString ?: @"" ;
[外设锁定]；
peripheralsByUUID[key] = peripheral;
[外设锁解锁]；
如果 (YCYLooksLikeLockName(peripheral.name) || lastLockUUID == nil ) {
lastLockUUID = 外围设备标识符；
最后锁定名称 = YCYPeripheralName(外设);
}
如果 (key.length && ![observedPeripheralIDs containsObject:key]) {
[observedPeripheralIDs addObject:key];
@尝试 {
[外围设备 addObserver:[YCYUnlockHelper 共享]
forKeyPath: @"state"
选项： NSKeyValueObservingOptionNew
context:kYCYStateObs];
} @catch ( NSException *ex) {
YCYLog( @"KVO 失败: %@" , ex.reason);
}
}
}

static NSArray *YCYConnectedPeripherals( void ) {
[外设锁定]；
NSArray *all = [peripheralsByUUID allValues];
[外设锁解锁]；
NSMutableArray *connected = [ NSMutableArray 数组];
for (CBPeripheral *p in all) {
如果 (p.state == CBPeripheralStateConnected) {
[已连接 addObject:p]；
} else if (p.state == CBPeripheralStateDisconnected) {
gNeedsRediscover = 是 ；
}
}
返回连接；
}

static CBCharacteristic *YCYFindCharacteristic(CBPeripheral *peripheral, NSString *serviceUUID, NSString *charUUID) {
（ void ）serviceUUID；
如果 (!peripheral.services) 返回 nil ；
for (CBService *service in peripheral.services) {
for (CBCharacteristic *c in service.characteristics) {
如果 (YCYUUIDMatch(c.UUID.UUIDString, charUUID)) {
返回 c；
}
}
}
返回 nil ；
}

static NSArray *YCYWriteCharacteristics(CBPeripheral *peripheral) {
NSMutableArray *result = [ NSMutableArray 数组];
如果 (!peripheral.services) 返回结果；
for (CBService *service in peripheral.services) {
如果 (!service.characteristics) 继续 ；
for (CBCharacteristic *c in service.characteristics) {
CBCharacteristicProperties p = c.properties;
BOOL canWrite = (p & CBCharacteristicPropertyWriteWithoutResponse) ||
（p & CBCharacteristicPropertyWrite）；
如果 (canWrite) [result addObject:c];
}
}
返回结果；
}

static void YCYEnableNotifies(CBPeripheral *peripheral) {
如果 (!peripheral.services) 返回 ；
for (CBService *service in peripheral.services) {
for (CBCharacteristic *c in service.characteristics) {
CBCharacteristicProperties p = c.properties;
如果 ((p & CBCharacteristicPropertyNotify) || (p & CBCharacteristicPropertyIndi​​cate)) {
YCYLog( @"开启通知 char=%@" , c.UUID.UUIDString);
[外围设备 setNotifyValue: YES forCharacteristic:c];
}
}
}
}

# pragma mark - Toast / 弹窗

static UIWindow *YCYHostWindow( void ) {
如果 （floatWindow 为真且 !floatWindow.hidden） 则返回 floatWindow；
UIApplication *application = [ UIApplication sharedApplication];
如果 (@available(iOS 13.0 , *)) {
for ( UIScene *scene in application.connectedScenes) {
如果 (scene.activationState != UISceneActivationStateForegroundActive ) 继续 ；
如果 (![scene isKindOfClass:[ UIWindowScene class ]]) continue ;
UIWindowScene *windowScene = ( UIWindowScene *)scene;
for ( UIWindow *window in windowScene.windows) {
如果 (window.isKeyWindow && !window.hidden) 返回 window;
}
for ( UIWindow *window in windowScene.windows) {
如果 (!window.hidden) 返回 window；
}
}
}
返回 nil ；
}

static UIViewController *YCYTopVC( void ) {
UIWindow *window = YCYHostWindow();
UIViewController *vc = window.rootViewController;
while (vc.presentedViewController) vc = vc.presentedViewController;
返回 vc；
}

static void YCYShowToast( NSString *text) {
dispatch_async (dispatch_get_main_queue(), ^{
UIWindow *window = YCYHostWindow();
如果 (!window) {
YCYLog( @"Toast 已跳过，无窗口：%@" , text);
返回 ;
}
如果 (!toastLabel) {
toastLabel = [[ UILabel alloc] init];
toastLabel.backgroundColor = [[ UIColor blackColor] colorWithAlphaComponent: 0.82 ];
toastLabel.textColor = [ UIColor 白色颜色];
toastLabel.font = [ UIFont systemFontOfSize: 13 ];
toastLabel.textAlignment = NSTextAlignmentCenter ;
toastLabel.numberOfLines = 0 ;
toastLabel.layer.cornerRadius = 10 ;
toastLabel.layer.masksToBounds = YES ;
}
toastLabel.text = [ NSString stringWithFormat: @" %@ " , text];
[toastLabel sizeToFit];
CGFloat w = MIN(window.bounds.size.width - 40 , MAX( 180 , toastLabel.bounds.size.width + 24 ));
CGFloat h = MAX( 36 , toastLabel.bounds.size.height + 16 );
toastLabel.frame = CGRectMake ((window.bounds.size.width - w) / 2.0 ,
window.bounds.size.height - 140 , w, h);
toastLabel.alpha = 0 ;
[window addSubview:toastLabel];
[ UIView animateWithDuration: 0.2 animations:^{ toastLabel.alpha = 1 ; }];
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)( 2.4 * NSEC_PER_SEC )),
dispatch_get_main_queue(), ^{
[ UIView animateWithDuration: 0.25 animations:^{
toastLabel.alpha = 0 ;
}完成:^( BOOL finished) {
（ 空 ）完成；
[toastLabel removeFromSuperview];
}];
});
});
}

static void YCYSetButtonBusy( BOOL busy) {
dispatch_async (dispatch_get_main_queue(), ^{
如果 (!floatButton) 返回 ；
floatButton.enabled = !busy;
floatButton.alpha = busy ? 0.55 : 1.0 ;
[floatButton setTitle:忙？ @"开锁中" : @"开锁" forState: UIControlStateNormal ];
});
}

# pragma mark - 分类：唯一密文 vs 心率

static void YCYReclassifyInPlace( NSMutableArray *items) {
for (YCYRecordedWrite *w in items) {
如果 (w.seenCount >= 2 ) {
w.heartbeatLike = YES ；
w.unlockLike = NO ;
} else if (!w.handshakeLike) {
w.heartbeatLike = NO ;
}
如果 (YCYLooksLikeUnlockPayload(w.value) || YCYLooksLikeStrongUnlock(w.value)) {
w.unlockLike = YES ；
w.heartbeatLike = NO ;
}
}
}

static NSArray *YCYUniqueUnlockPackets( NSArray *burst) {
如果 (burst.count == 0 ) 返回 @[];

NSMutableArray * strong = [ NSMutableArray 数组];
for (YCYRecordedWrite *item in burst) {
如果 (YCYLooksLikeStrongUnlock(item.value)) [ strong addObject:item];
}
如果 ( strong .count) 返回 strong ;

NSMutableArray *unique = [ NSMutableArray 数组];
for (YCYRecordedWrite *item in burst) {
如果 (item.handshakeLike) 继续 ；
如果 (item.heartbeatLike || item.seenCount >= 2 ) 继续 ；
[唯一添加对象：item]；
}
如果 (unique.count == 0 ) 返回 @[];

YCYRecordedWrite *last = unique.lastObject;
NSMutableArray *tail = [ NSMutableArray 数组];
for (YCYRecordedWrite *w in unique) {
NSTimeInterval dt = last.time && w.time ? [last.time timeIntervalSinceDate:w.time] : 0 ;
如果 (dt <= 0.85 ) [tail addObject:w];
}
返回 tail.count ? tail : unique;
}

# pragma mark - 持久化

static NSDictionary *YCYWriteToDict(YCYRecordedWrite *item) {
返回 @{
@"pid" : item.peripheralID.UUIDString ?: @"" ,
@"name" : item.peripheralName ?: @"" ,
@"svc" : item.serviceUUID ?: @"" ,
@"char" : item.charUUID ?: @"" ,
@"value" : [item.value base64EncodedStringWithOptions: 0 ] ?: @"" ,
@"type" : @(item.type),
@"time" : @([item.time timeIntervalSince1970]),
@"unlockLike" : @(item.unlockLike),
@"handshakeLike" : @(item.handshakeLike),
@"heartbeatLike" : @(item.heartbeatLike),
@"seenCount" : @(item.seenCount),
};
}

static YCYRecordedWrite *YCYWriteFromDict( NSDictionary *d) {
如果 (![d isKindOfClass:[ NSDictionary 类 ]]) 返回 nil ;
YCYRecordedWrite *item = [YCYRecordedWrite new];
NSString *pid = d[ @"pid" ];
如果 ([pid isKindOfClass:[ NSString class ]] && pid.length) {
item.peripheralID = [[ NSUUID alloc] initWithUUIDString:pid];
}
item.peripheralName = [d[ @"name" ] isKindOfClass:[ NSString class ]] ? d[ @"name" ] : @"" ;
item.serviceUUID = [d[ @"svc" ] isKindOfClass:[ NSString class ]] ? d[ @"svc" ] : @"" ;
item.charUUID = [d[ @"char" ] isKindOfClass:[ NSString class ]] ? d[ @"char" ] : @"" ;
NSString *b64 = d[ @"value" ];
如果 ([b64 isKindOfClass:[ NSString class ]]) {
item.value = [[ NSData alloc] initWithBase64EncodedString:b64 options: 0 ];
}
item.type = [d[ @"type" ] integerValue];
item.time = [ NSDate dateWithTimeIntervalSince1970:[d[ @"time" ] doubleValue]];
item.unlockLike = [d[ @"unlockLike" ] boolValue];
item.handshakeLike = [d[ @"handshakeLike" ] boolValue];
item.heartbeatLike = [d[ @"heartbeatLike" ] boolValue];
item.seenCount = [d[ @"seenCount" ] unsignedIntegerValue];
如果 (!item.value) 返回 nil ；
退货 ；
}

static void YCYPersistRecords( void ) {
[recordLock 锁定]；
NSMutableArray *arr = [ NSMutableArray 数组];
for (YCYRecordedWrite *item in canonicalWrites) {
[arr addObject:YCYWriteToDict(item)];
}
BOOL frozen = gCanonicalFrozen;
NSString *uuid = lastLockUUID.UUIDString;
NSString *name = lastLockName;
[recordLock 解锁]；

NSUserDefaults *ud = [ NSUserDefaults standardUserDefaults];
[ud setObject:arr forKey:kYCYRecordsKey];
[ud setBool:frozen forKey: @"YCYUnlock.frozen" ];
如果 (uuid) [ud setObject:uuid forKey:kYCYLockUUIDKey];
如果 (name) [ud setObject:name forKey:kYCYLockNameKey];
[ud 同步]；
}

static void YCYLoadRecords( void ) {
NSUserDefaults *ud = [ NSUserDefaults standardUserDefaults];
NSArray *arr = [ud arrayForKey:kYCYRecordsKey];
如果 (arr.count == 0 ) {
arr = [ud arrayForKey:kYCYRecordsKeyV2];
}
[canonicalWrites removeAllObjects];
for ( NSDictionary *d in arr) {
YCYRecordedWrite *item = YCYWriteFromDict(d);
如果 (item) [canonicalWrites addObject:item];
}
YCYReclassifyInPlace(canonicalWrites);
BOOL hasFreq = NO ;
for (YCYRecordedWrite *w in canonicalWrites) {
如果 (w.seenCount >= 1 || w.heartbeatLike) { hasFreq = YES ; break ; }
}
如果 (!hasFreq && canonicalWrites.count > 1 ) {
NSLog ( @"[YCYUnlock] 旧记录没有频率信息，已丢弃 %lu 条，请重新官方开锁一次" ,
( unsigned long )canonicalWrites.count);
[canonicalWrites removeAllObjects];
gCanonicalFrozen = 否 ；
} 别的 {
NSArray *unique = YCYUniqueUnlockPackets(canonicalWrites);
如果 (unique.count > 0 && unique.count < canonicalWrites.count) {
NSLog ( @"[YCYUnlock] 加载后明显除心跳 %lu → 唯一 %lu" ,
( unsigned long )canonicalWrites.count, ( unsigned long )unique.count);
[canonicalWrites removeAllObjects];
[canonicalWrites addObjectsFromArray:unique];
}
gCanonicalFrozen = [ud boolForKey: @"YCYUnlock.frozen" ] && canonicalWrites.count > 0 ;
如果 (canonicalWrites.count > 0 && unique.count > 0 ) {
gCanonicalFrozen = 是 ；
}
}
NSString *uuid = [ud stringForKey:kYCYLockUUIDKey];
if (uuid.length) lastLockUUID = [[ NSUUID alloc] initWithUUIDString:uuid];
lastLockName = [ud stringForKey:kYCYLockNameKey];
}

# pragma mark - 记录 / 重放

static NSArray *YCYCanonicalCopy( void ) {
[recordLock 锁定]；
NSArray *all = [canonicalWrites copy ];
[recordLock 解锁]；
返回全部；
}

static void YCYFreezeCanonicalFromSession( void ) {
[recordLock 锁定]；
YCYReclassifyInPlace(liveSession);
NSArray *unique = YCYUniqueUnlockPackets(liveSession);
BOOL didFreeze = NO ;
如果 (unique.count > 0 ) {
[canonicalWrites removeAllObjects];
[canonicalWrites addObjectsFromArray:unique];
for (YCYRecordedWrite *w in canonicalWrites) {
w.unlockLike = YES ；
w.heartbeatLike = NO ;
}
gCanonicalFrozen = 是 ；
didFreeze = YES ；
gFrozenSessionGen = gSessionGen;
YCYLog( @"★ 冻结唯一开锁包 %lu 条（已丢弃心跳/重复，关锁不再覆盖）" ,
( unsigned long )canonicalWrites.count);
for (YCYRecordedWrite *w in canonicalWrites) {
YCYLog( @" 冻结 HEX=%@" , YCYHexString(w.value));
}
} 别的 {
YCYLog( @" 冻结跳过：当前会话没有唯一密文（可能尚未官方开锁） live=%lu" ,
( unsigned long )liveSession.count);
}
[recordLock 解锁]；
如果 (didFreeze) YCYPersistRecords();
}

static void YCYScheduleFreeze( void ) {
如果 (gCanonicalFrozen) 返回 ；
如果 (gFreezeBlock) {
dispatch_block_cancel(gFreezeBlock);
gFreezeBlock = nil ；
}
dispatch_block_t block = dispatch_block_create( 0 , ^{
gFreezeBlock = nil ；
如果 (!gCanonicalFrozen) YCYFreezeCanonicalFromSession();
});
gFreezeBlock = block;
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)( 2.0 * NSEC_PER_SEC )),
dispatch_get_main_queue(), block);
}

static void YCYRecordWrite(CBPeripheral *外设,
CB 特性 *特性，
NSData *data，
CBCharacteristicWriteType 类型) {
如果 (gIgnoreHookWrite) 返回 ；
如果 (!外设 || !特征 || !数据) 返回 ；

lastAppPeripheral = 外围设备；
lastAppWriteTime = [ NSDate date];
gNeedsRediscover = 否 ；

NSString *charUUID = characteristic.UUID.UUIDString ?: @"" ;
BOOL target = YCYIsTargetCharacteristic(charUUID) || YCYLooksLikeUnlockPayload(data);
如果 (!target) 返回 ；

NSString *hex = YCYHexString(data);

[recordLock 锁定]；
NSInteger seen = [payloadCounts[hex] integerValue] + 1 ;
payloadCounts[hex] = @(seen);
[recordLock 解锁]；

如果 (gCanonicalFrozen) {
YCYLog( @"已冻结，忽略写包 unique=%@ count=%ld HEX=%@" ,
seen == 1 ? @"YES" : @"NO" , ( long )seen, hex);
lastLockUUID = 外围设备标识符；
最后锁定名称 = YCYPeripheralName(外设);
返回 ;
}

BOOL handshakeSkip = NO ;
如果 (gHandshakeWritesLeft > 0 ) {
gHandshakeWritesLeft--;
handshakeSkip = YES ;
}
如果 (gHandshakeUntil && [gHandshakeUntil timeIntervalSinceNow] > 0 ) {
handshakeSkip = YES ;
}
如果 （跳过握手）{
YCYLog( @"握手包，跳过记录 left=%ld HEX=%@" , ( long )gHandshakeWritesLeft, hex);
lastLockUUID = 外围设备标识符；
最后锁定名称 = YCYPeripheralName(外设);
返回 ;
}

YCYRecordedWrite *item = [YCYRecordedWrite new];
item.peripheralID = peripheral.identifier;
item.peripheralName = YCYPeripheralName(peripheral);
item.serviceUUID = characteristic.service.UUID.UUIDString ?: @"" ;
item.charUUID = charUUID;
item.value = [数据副本 ];
item.type = type;
item.time = [ NSDate 日期];
item.handshakeLike = NO ;
item.seenCount = ( NSUInteger )seen;
item.heartbeatLike = (已查看 >= 2 );
item.unlockLike = (!item.heartbeatLike);

lastLockUUID = 外围设备标识符；
最后锁定名称 = item.peripheralName;

[recordLock 锁定]；
YCYRecordedWrite *last = liveSession.lastObject;
如果 (last && [item.time timeIntervalSinceDate:last.time] > 12.0 ) {
[liveSession removeAllObjects];
}
BOOL dup = NO ;
如果 (liveSession.count > 0 ) {
YCYRecordedWrite *prev = liveSession.lastObject;
如果 ([prev.charUUID 等于 item.charUUID] &&
[prev.value isEqualToData:item.value]) {
重复 = 是 ；
prev.seenCount = ( NSUInteger )seen;
prev.heartbeatLike = YES ;
prev.unlockLike = NO ;
}
}
如果 (!dup) {
[liveSession addObject:item];
如果 (liveSession.count > 20 ) {
[liveSession removeObjectsInRange: NSMakeRange ( 0 , liveSession.count - 20 )];
}
}
NSUInteger liveCount = liveSession.count;
[recordLock 解锁]；

YCYLog( @"★记录%@ count=%ld live=%lu char=%@ HEX=%@" ,
item.heartbeatLike ？ @"心跳/重复" : @"唯一候选" ,
（ 很久以前 ）见过，
( 无符号长整型 )liveCount，
字符 UUID，
十六进制）；

如果 (!item.heartbeatLike) {
YCYScheduleFreeze();
}
}

static CBCharacteristicWriteType YCYResolvedType(CBCharacteristic *characteristic,
CBCharacteristicWriteType（首选）{
BOOL canWith = (characteristic.properties & CBCharacteristicPropertyWrite) != 0 ;
BOOL canWithout = (characteristic.properties & CBCharacteristicPropertyWriteWithoutResponse) != 0 ;
如果 (preferred == CBCharacteristicWriteWithResponse) {
如果 (canWith) 返回 CBCharacteristicWriteWithResponse；
如果 (canWithout) 返回 CBCharacteristicWriteWithoutResponse；
} 别的 {
如果 (canWithout) 返回 CBCharacteristicWriteWithoutResponse；
如果 (canWith) 返回 CBCharacteristicWriteWithResponse；
}
返回 canWith ? CBCharacteristicWriteWithResponse : CBCharacteristicWriteWithoutResponse;
}

static BOOL YCYWriteData(CBPeripheral *peripheral,
CB 特性 *特性，
NSData *data，
CBCharacteristicWriteType（首选）{
如果 (!外设 || !特征 || !数据) 返回 NO ；
如果 (外围设备.状态 != CBPeripheralStateConnected) {
YCYLog( @" 读取跳过：未连接 name=%@" , YCYPeripheralName(peripheral));
返回 NO ；
}

CBCharacteristicWriteType type = YCYResolvedType(characteristic, preferred);

@尝试 {
[外设 writeValue:data forCharacteristic:characteristic type:type];
YCYLog( @"已写入 name=%@ char=%@ type=%@ len=%lu HEX=%@" ,
YCYPeripheralName(外围设备)
特征.UUID.UUIDString，
type == CBCharacteristicWriteWithResponse ? @"WithResponse" : @"WithoutResponse" ,
( 无符号长整型 )数据.长度，
YCYHexString(data));
返回 YES ；
} @catch ( NSException *ex) {
YCYLog( @" 写入异常: %@" , ex.reason);
返回 NO ；
}
}

static CBPeripheral *YCYPickPeripheral( NSArray *connected, NSUUID *preferID) {
CBPeripheral *appP = lastAppPeripheral;
如果 (appP && appP.state == CBPeripheralStateConnected) 返回 appP;
如果 (preferID) {
for (CBPeripheral *p in connected) {
如果 ([p.identifier isEqual:preferID]) 返回 p;
}
}
for (CBPeripheral *p in connected) {
如果 (YCYLooksLikeLockName(p.name)) 返回 p;
}
返回 connected.firstObject；
}

static CBCharacteristic *YCYPickWriteChar(CBPeripheral *target, YCYRecordedWrite *item) {
CBCharacteristic *ch = YCYFindCharacteristic(target, item.serviceUUID, item.charUUID);
如果 (ch) 返回 ch；
for (CBCharacteristic *c in YCYWriteCharacteristics(target)) {
如果 (YCYIsTargetCharacteristic(c.UUID.UUIDString)) 返回 c;
}
返回 YCYWriteCharacteristics(target).firstObject;
}

static void YCYFinishUnlockFlight( void ) {
gIgnoreHookWrite = NO ;
gUnlockInFlight = 否 ；
YCYSetButtonBusy( 否 );
}

static NSInteger YCYReplayBurstOnPeripheral( NSArray *burst, CBPeripheral *forced) {
NSArray *packets = YCYUniqueUnlockPackets(burst);
如果 （packets.count == 0 ）{
YCYLog( @"重放取消：没有唯一开锁包（避免把心跳当开锁）记录=%lu" ,
( unsigned long )burst.count);
YCYFinishUnlockFlight();
返回 0 ；
}

YCYLog( @"开始重放唯一包包=%lu / 记录=%lu needRediscover=%d" ,
( unsigned long )packets.count, ( unsigned long )burst.count, gNeedsRediscover);
for (YCYRecordedWrite *p in packets) {
YCYLog( @" 将发送 HEX=%@" , YCYHexString(p.value));
}

gIgnoreHookWrite = 是 ；
YCYEnableNotifies(forced);

NSArray *connected = YCYConnectedPeripherals();
NSMutableArray *pool = [connected mutableCopy] ?: [ NSMutableArray array];
如果 （强制 && 强制状态 == CBPeripheralStateConnected）{
BOOL 存在 = NO ;
for (CBPeripheral *p in pool) {
如果 (p == forced || [p.identifier isEqual:forced.identifier]) { exists = YES ; break ; }
}
如果 (!exists) [池 addObject:forced];
}

__block NSInteger sent = 0 ;
void (^sendOne)(YCYRecordedWrite *) = ^(YCYRecordedWrite *item) {
CBPeripheral *target = YCYPickPeripheral(pool, item.peripheralID ?: lastLockUUID);
如果 (!target) 则 target = forced;
如果 (!target || target.state != CBPeripheralStateConnected) {
YCYLog( @"重放失败：没有可用设备" );
返回 ;
}
CBCharacteristic *ch = YCYPickWriteChar(target, item);
如果 (!ch) {
YCYLog( @"重放失败：找不到可写特征 %@" , item.charUUID);
返回 ;
}
如果 (YCYWriteData(target, ch, item.value, item.type)) sent++;
};

NSTimeInterval gap = 0.18 ;
for ( NSUInteger i = 0 ; i < packets.count; i++) {
YCYRecordedWrite *item = packets[i];
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * gap * NSEC_PER_SEC )),
dispatch_get_main_queue(), ^{
sendOne(item);
});
}

NSTimeInterval extraAt = packet.count * 间隙；
如果 （packets.count == 1 ）{
YCYRecordedWrite *only = packets.firstObject;
extraAt += 0.28 ;
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(extraAt * NSEC_PER_SEC )),
dispatch_get_main_queue(), ^{
sendOne(仅)；
});
}

NSTimeInterval 总计 = extraAt + 0.6 ；
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(total * NSEC_PER_SEC )),
dispatch_get_main_queue(), ^{
YCYLog( @"重放结束发送≈%ld" ,( long )sent);
YCYFinishUnlockFlight();
});
返回 ( NSInteger )packets.count；
}

# pragma mark - JSContext（UniApp 服务层）

static void YCYRememberJSContext(JSContext *ctx) {
如果 (!ctx || gInJSProbe) 返回 ；
YCYInitState();
@synchronized (jsContexts) {
[jsContexts addObject:ctx];
}
static BOOL probed = NO ;
如果 （已探测到） 返回 ；
已探测 = 是 ；
gInJSProbe = 是 ；
@尝试 {
JSValue *v = [ctx evaluateScript:
@"(function(){var a=[];function w(o,p,d){if(!o||d>3)return;try{var ks=Object.keys(o);for(var i=0;i<ks.length&&i<60;i++){var k=ks[i];if(/ble|open|lock|unlock|jm|ys0|dcble/i.test(k))a.push(p+k);var v=o[k];if(v&&typeof v==='object')w(v,p+k+'.',d+1);}}catch(e){}}"
"try{if(typeof _ble_do==='function')a.push('_ble_do');"
"if(typeof _init_ble==='function')a.push('_init_ble');"
"if(typeof plus!=='undefined'){a.push('plus');w(plus,'plus.',2);}"
"if(typeof uni!=='undefined'){a.push('uni');w(uni,'uni.',2);}"
"if(typeof weex!=='undefined')a.push('weex');"
"if(typeof getApp==='function'){a.push('getApp');try{w(getApp(),'app.',2);}catch(e){}}"
"}catch(e){}return a.slice(0,40).join(',')||'none';})()" ];
YCYLog( @"JSContext probe globals=%@" , v.isString ? v.toString : @"?" );
} @catch ( NSException *ex) {
YCYLog( @"JS 探测异常: %@" , ex.reason);
}
gInJSProbe = 否 ；
}

static BOOL YCYTryJSOpen( void ) {
NSArray *ctxs;
@synchronized (jsContexts) {
ctxs = [[jsContexts allObjects] copy ];
}
如果 (ctxs.count == 0 ) {
YCYLog( @"无 JSContext，跳过 App 内部开锁" );
返回 NO ；
}
NSString *script =
@"(function(){try{"
"if(typeof _ble_do==='function'){_ble_do('open');return 'opened:_ble_do';}"
"if(typeof _init_ble==='function'){_init_ble('open');return 'opened:_init_ble';}"
"if(typeof uni!=='undefined'&&uni.$emit){uni.$emit('ycy-force-open');return 'opened:uni.emit';}"
返回“miss”；
"}catch(e){return 'err:'+String(e);}})()" ;
gInJSProbe = 是 ；
BOOL opened = NO ;
for (JSContext *ctx in ctxs) {
@尝试 {
JSValue *v = [ctx evaluateScript:script];
NSString *s = v.isString ? v.toString : @"nil" ;
YCYLog( @"JS 打开结果=%@" , s);
如果 ([s hasPrefix: @"opened:" ]) opened = YES ;
} @catch ( NSException *ex) {
YCYLog( @"JS 打开异常: %@" , ex.reason);
}
}
gInJSProbe = 否 ；
退货已开启；
}

# pragma mark - 自建 BLE 连接

@interface YCYBleEngine : NSObject < CBCentralManagerDelegate , CBPeripheralDelegate >
@property ( nonatomic , strong ) CBCentralManager *central;
@property ( nonatomic , strong ) CBPeripheral *target;
@property ( nonatomic , copy ) NSArray *pendingBurst;
@property ( nonatomic , assign ) BOOL busy;
@property ( nonatomic , assign ) BOOL 重放;
@property ( nonatomic , assign ) NSInteger pendingDiscover;
@property ( nonatomic , assign ) NSUInteger 生成;
@结尾

静态 YCYBleEngine *gEngine；

@implementation YCYBleEngine

+ ( 实例类型 )共享{
static dispatch_once_t once;
dispatch_once (&once, ^{ gEngine = [YCYBleEngine new]; });
返回 gEngine；
}

- ( void )failWith:( NSString *)msg {
YCYLog( @"连接流程失败: %@" , msg);
self.busy = NO ;
self.replayed = YES ;
YCYFinishUnlockFlight();
[ self.central stopScan];
YCYShowToast(msg);
}

- ( void )finishReplayOn:(CBPeripheral *)peripheral {
如果 （ self.replayed ） 返回 ；
self.replayed = YES ;
self.busy = NO ;
[ self.central stopScan];
NSInteger n = YCYReplayBurstOnPeripheral( self.pendingBurst , peripheral);
如果 (n <= 0 ) {
YCYShowToast( @"已连接，但没有唯一开锁包\n 请先官方开锁一次" );
} 别的 {
YCYShowToast([ NSString stringWithFormat: @"已连接，正在重放 %ld 条唯一指令" , ( long )n]);
}
}

- ( BOOL )hasWriteChars:(CBPeripheral *)p {
返回 YCYWriteCharacteristics(p).count > 0 ；
}

- ( void )discoverOn:(CBPeripheral *)peripheral {
self.target = peripheral;
peripheral.delegate = self ;
YCYLog( @"开始发现服务（强制刷新） %@" , YCYPeripheralName(peripheral));
NSArray *svcs = @[
[CBUUID UUIDWithString:kYCYSvc9000],
[CBUUID UUIDWithString:kYCYSvcAE00]
];
[外围设备发现服务:svcs]；
__weak typeof ( self ) weakSelf = self ;
NSUInteger gen = self.generation ;
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)( 1.2 * NSEC_PER_SEC )),
dispatch_get_main_queue(), ^{
如果 (weakSelf.generation != gen) 返回 ；
如果 (!weakSelf.replayed && peripheral.services.count == 0 ) {
[外围设备发现服务: nil ];
}
});
}

- ( void )connectPeripheral:(CBPeripheral *)peripheral {
如果 （!外设） 返回 ；
YCYLog( @"正在连接 %@ %@" , YCYPeripheralName(peripheral),peripheral.identifier.UUIDString);
YCYShowToast([ NSString stringWithFormat: @"正在连接 %@" , YCYPeripheralName(peripheral)]);
self.target = peripheral;
[ self.central stopScan];
[ self .central connectPeripheral:外设选项: nil ];
}

- ( void )beginWithBurst:( NSArray *)burst {
self.pendingBurst = burst;
self.replayed = NO ;
self.busy = YES ;
self.target = nil ;
self.pendingDiscover = 0 ;
self.generation += 1 ;
NSUInteger gen = self.generation ;

如果 (! self.central ) {
self.central = [[CBCentralManager alloc] initWithDelegate: self
队列:dispatch_get_main_queue()
options:@{CBCentralManagerOptionShowPowerAlertKey: @YES}];
} 别的 {
[ self centralManagerDidUpdateState: self.central ];
}

dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)( 15 * NSEC_PER_SEC )),
dispatch_get_main_queue(), ^{
如果 ( self.generation == gen && self.busy && ! self.replayed ) {
[ self failureWith: @"搜索锁盒超时\n 请把 YS04 靠近手机恢复试" ];
}
});
}

- ( void )tryRetrieveAndScan {
CBCentralManager *c = self.central ;

NSMutableArray *ids = [ NSMutableArray 数组];
if (lastLockUUID) [ids addObject:lastLockUUID];
for (YCYRecordedWrite *w in self.pendingBurst ) {
如果 (w.peripheralID) [ids addObject:w.peripheralID];
}

NSArray *svcs = @[
[CBUUID UUIDWithString:kYCYSvc9000],
[CBUUID UUIDWithString:kYCYSvcAE00]
];

如果 (ids.count > 0 ) {
NSArray *known = [c retrievePeripheralsWithIdentifiers:ids];
YCYLog( @"retrievePeripherals count=%lu" , ( unsigned long )known.count);
如果 (已知计数 > 0 ) {
[ 自我连接外围设备:已知.第一个对象];
返回 ;
}
}

NSArray *already = [c retrieveConnectedPeripheralsWithServices:svcs];
YCYLog( @"retrieveConnected count=%lu" , ( unsigned long )already.count);
如果 (已计数 > 0 ) {
CBPeripheral *pick = already.firstObject;
for (CBPeripheral *p in already) {
if (YCYLooksLikeLockName(p.name)) { pick = p; break ; }
}
如果 (pick.state == CBPeripheralStateConnected) {
[ 自我发现 On:pick];
} 别的 {
[ 自连接外设:拾取];
}
返回 ;
}

YCYLog( @"开始扫描 YS04" );
YCYShowToast( @"正在搜索 YS04…" );
[c scanForPeripheralsWithServices: nil
options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
}

- ( void )centralManagerDidUpdateState:(CBCentralManager *)central {
如果 (central.state != CBManagerStatePoweredOn) {
如果 （ self.busy ）{
[ self failureWith: @"系统蓝牙未打开" ];
}
返回 ;
}
如果 ( self.busy && ! self.replayed ) {
[ 自我尝试检索和扫描];
}
}

- ( void )centralManager:(CBCentralManager *)central
didDiscoverPeripheral:(CBPeripheral *)外设
advertisementData:( NSDictionary < NSString *, id > *)advertisementData
RSSI:( NSNumber *)RSSI {
（ 空 ）中心；
NSString *name = peripheral.name.length
外围设备名称
: advertisementData[CBAdvertisementDataLocalNameKey];
YCYLog( @"扫描到 name=%@ uuid=%@ rssi=%@" , name,peripheral.identifier.UUIDString, RSSI);

BOOL match = YCYLooksLikeLockName(name);
如果 (!match && lastLockUUID && [peripheral.identifier isEqual:lastLockUUID]) match = YES ;
for (YCYRecordedWrite *w in self.pendingBurst ) {
如果 (w.peripheralID && [peripheral.identifier isEqual:w.peripheralID]) match = YES ;
}
如果 (!match) 返回 ；

[ 自连接外设:外设];
}

- ( void )centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
（ 空 ）中心；
YCYLog( @"已连接 %@" , YCYPeripheralName(peripheral));
[ 自我发现开启：外围设备]；
}

- ( void )centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)外设
错误:( NSError *)error {
（ 空 ）中心；
（ 空 ）外围；
[ self failureWith:[ NSString stringWithFormat: @"连接失败: %@" , error.localizedDescription ?: @"未知错误" ]];
}

- ( void )centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral
错误:( NSError *)error {
（ 空 ）中心；
YCYLog( @"engine 断开 %@ err=%@" , YCYPeripheralName(peripheral), error);
gNeedsRediscover = 是 ；
如果 ( self.busy && ! self.replayed ) {
[ self failureWith: @"连接已断开，请关闭锁盒重新试" ];
}
}

- ( void )peripheral:(CBPeripheral *)peripheral didDiscoverServices:( NSError *)error {
如果 （错误）{
YCYLog( @"发现服务失败 %@" , error);
}
self.pendingDiscover = 0 ;
如果 （外围服务数量 == 0 ）{
[ self failureWith: @"已连接但没有发现服务" ];
返回 ;
}
for (CBService *s in peripheral.services) {
self.pendingDiscover ++;
[外围设备发现特性： nil forService:s];
}
}

- ( void )外设:(CBPeripheral *)外设
didDiscoverCharacteristicsForService:(CBService *)service
错误:( NSError *)error {
（ 无效 ）服务；
（ void ）错误；
self.pendingDiscover-- ;
如果 ( self.pendingDiscover <= 0 && ! self.replayed ) {
如果 ([ self hasWriteChars:peripheral]) {
YCYEnableNotifies(外围设备);
__weak typeof ( self ) weakSelf = self ;
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)( 0.35 * NSEC_PER_SEC )),
dispatch_get_main_queue(), ^{
[weakSelf finishReplayOn:外设];
});
} 别的 {
[ self failureWith: @"已连接但没有可写特征" ];
}
}
}

- ( void )外设:(CBPeripheral *)外设
didWriteValueForCharacteristic:(CBCharacteristic *)characteristic
错误:( NSError *)error {
（ 空 ）外围；
如果 （错误）{
YCYLog( @"调用回调失败 char=%@ err=%@" ,characteristic.UUID.UUIDString, error);
} 别的 {
YCYLog( @"调用回调成功 char=%@" ,characteristic.UUID.UUIDString);
}
}

- ( void )外设:(CBPeripheral *)外设
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
错误:( NSError *)error {
（ void ）错误；
YCYLog( @"通知名称=%@ char=%@ HEX=%@" ,
YCYPeripheralName(外围设备)
特征.UUID.UUIDString，
YCYHexString(characteristic.value));
}

@结尾

# pragma mark - 开锁入口

static void YCYDoReplay( NSArray *burst, CBPeripheral *ready) {
NSInteger n = YCYReplayBurstOnPeripheral(burst, ready);
如果 (n <= 0 ) {
YCYShowToast( @"没有唯一开锁包\n 请先让控方同意并成功开锁一次" );
} 别的 {
YCYShowToast([ NSString stringWithFormat: @"正在重放 %ld 条唯一指令" , ( long )n]);
}
}

static void YCYTryUnlockWithBurst( NSArray *burst, BOOL tryJS) {
YCYInitState();
如果 (gUnlockInFlight) {
YCYShowToast( @"正在开锁，请稍候" );
返回 ;
}

NSArray *connected = YCYConnectedPeripherals();
CBPeripheral *准备好= YCYPickPeripheral（已连接，lastLockUUID）;
BOOL appConnected = ready && ready.state == CBPeripheralStateConnected;

// 修复 1：只要未重新产生断开/重新发现标识且世代未变，同连接会话内部即认为有效
BOOL sameSession = appConnected && !gNeedsRediscover
&& (gFrozenSessionGen == 0 || gFrozenSessionGen == gSessionGen);

YCYLog( @"尝试开锁已连接=%lu SameSession=%d freeze=%d js=%d native=%@ session=%lu/%lu" ,
( 无符号长整型 )连接数，
sameSession，
gCanonicalFrozen，
tryJS，
gDCBLE ? NSStringFromClass ([gDCBLE class ]) : @"nil" ,
（ 无符号长整型 ）gFrozenSessionGen，
（ 无符号长整型 ）gSessionGen）；

gUnlockInFlight = YES ；
YCYSetButtonBusy( 是 );

// 1) 初始 DCBLEManager：如果已连接且握手结束，优先让 App 使用当前会话密钥组包
如果 (appConnected && gHandshakeWritesLeft <= 0 && YCYTryNativeOpen()) {
YCYShowToast( @"已调用 DCBLEManager 开锁" );
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)( 2.5 * NSEC_PER_SEC )),
dispatch_get_main_queue(), ^{
YCYFinishUnlockFlight();
});
返回 ;
}

// 2) JS 兜底
如果 (appConnected && gHandshakeWritesLeft <= 0 && tryJS && YCYTryJSOpen()) {
YCYShowToast( @"已调用 App 内部 JS 开锁" );
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)( 2.2 * NSEC_PER_SEC )),
dispatch_get_main_queue(), ^{
YCYFinishUnlockFlight();
});
返回 ;
}

// 3) 未连接或断电状态：走 App 的 CBCentralManager 重连
如果 (!appConnected) {
YCYLog( @"未连接，走 appCentral 重连（禁止盲放旧密文）" );
BOOL started = YCYConnectViaAppCentral();
如果 （已开始）{
YCYShowToast( @"锁盒已断电或断连\n 正在让 App 重连并自动开锁..." );

// 修复 2：采用状态轮询检测替代死板延迟，等待应用程序重新完成握手并发送新的挑战包
__block int attempts = 0 ;
__block void (^retryBlock)( void ) = nil ;
__block __ weak void (^weakRetry)( void ) = nil ;
重试块 = ^{
尝试次数++；
BOOL isReady = (lastAppPeripheral.state == CBPeripheralStateConnected);
BOOL handshakeDone = (gHandshakeWritesLeft <= 0 );

如果 （isReady && handshakeDone）{
如果 (YCYTryNativeOpen()) {
YCYShowToast( @"握手完成，已调用 DCBLEManager 开锁" );
YCYFinishUnlockFlight();
返回 ;
} else if (tryJS && YCYTryJSOpen()) {
YCYShowToast( @"握手完成，已调用 JS 开锁" );
YCYFinishUnlockFlight();
返回 ;
}
}

如果 （尝试次数 < 7 ）{
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)( 1.5 * NSEC_PER_SEC )), dispatch_get_main_queue(), weakRetry);
} 别的 {
YCYShowToast( @"重连/握手超时，尝试强制发送指令..." );
如果 (YCYTryNativeOpen()) {
YCYShowToast( @"已强制触发 DCBLEManager" );
} 别的 {
YCYShowToast( @"未能触发裂缝开锁，请看日志 dump" );
}
YCYFinishUnlockFlight();
}
};
weakRetry = retryBlock;

dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)( 2.0 * NSEC_PER_SEC )),
dispatch_get_main_queue(), retryBlock);
返回 ;
}
YCYFinishUnlockFlight();
YCYShowToast( @"无法让 App 重连\n 请先打开 App 蓝牙页再试" );
返回 ;
}

// 4) 允许仍是同一会话才重放旧密文
如果 (!sameSession) {
YCYLog( @"会话已变，拒绝重放旧密文 needsRediscover=%d" , gN​​eedsRediscover);
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)( 2.0 * NSEC_PER_SEC )), dispatch_get_main_queue(), ^{
如果 (YCYTryNativeOpen()) {
YCYShowToast( @"新会话已调用间歇指令开锁" );
} 别的 {
YCYShowToast( @"当前是新连接，旧密文失效\n 初次没匹配到方法，请发日志" );
}
YCYFinishUnlockFlight();
});
返回 ;
}

如果 (!gCanonicalFrozen) {
YCYFreezeCanonicalFromSession();
}
NSArray *effective = burst;
如果 （有效计数 == 0 ）{
effective = YCYUniqueUnlockPackets(YCYCanonicalCopy());
} 别的 {
NSArray *filtered = YCYUniqueUnlockPackets(effective);
如果 (filtered.count) 有效 = 已过滤;
}
如果 （有效计数 == 0 ）{
YCYFinishUnlockFlight();
YCYShowToast( @"同一会话内也没有可重放的包\n 请确认已由控方正常开锁过" );
返回 ;
}
YCYDoReplay（有效，准备就绪）；
}

static void YCYTryUnlock( void ) {
YCYTryUnlockWithBurst( nil , YES );
}

# pragma mark - 日志 / 记录 UI

static void YCYShowLogs( void ) {
dispatch_async (dispatch_get_main_queue(), ^{
[bleLogLock 锁定]；
NSString *text = bleLogs.count
? [bleLogs componentsJoinedByString: @"\n" ]
: @"暂无 BLE 日志" ;
[bleLogLock 解锁]；

UIAlertController *alert =
[ UIAlertController alertControllerWithTitle: @"YCY BLE 日志"
消息：文本
preferredStyle: UIAlertControllerStyleAlert ];
[alert addAction:[ UIAlertAction actionWithTitle: @"关闭"
样式： UIAlertActionStyleDefault
处理程序： nil ]];
[YCYTopVC() presentViewController:alert animated: YES completion: nil ];
});
}

static void YCYShowRecords( void ) {
dispatch_async (dispatch_get_main_queue(), ^{
NSArray *all = YCYCanonicalCopy();
NSArray *unique = YCYUniqueUnlockPackets(all);
NSMutableString *text = [ NSMutableString string];
如果 (all.count == 0 ) {
[textappendString: @"暂无已记录的开锁指令\n 请先让控方正常同意并成功开锁一次\n 插件只保存「只出现一次」的密文，心跳会被丢掉" ];
} 别的 {
[text appendFormat: @"状态：%@\n 唯一包：%lu 原始：%lu\n\n" ,
gCanonicalFrozen ？ @"已冻结（只重放唯一包）" : @"采集中" ,
( 无符号长整型 )唯一计数，
( 无符号长整型 )all.count];
NSInteger i = 1 ;
for (YCYRecordedWrite *item in unique.count ? unique : all) {
[text appendFormat: @"%ld. %@ %@\n%@\n\n" ,
（ 长 ）i++，
item.heartbeatLike ？ @"[心跳]" : @"[唯一]" ,
item.外设名称，
YCYHexString(item.value)];
}
}

UIAlertController *alert =
[ UIAlertControlleralertControllerWithTitle : @"已记录的唯一开锁包"
消息：文本
preferredStyle: UIAlertControllerStyleAlert ];

NSInteger idx = 0 ;
for (YCYRecordedWrite *item in unique) {
如果 (idx >= 4 ) 跳出 ；
NSString *title = [ NSString stringWithFormat: @"重放第 %ld 条 %@" ,
( long )(idx + 1 ), YCYShortHex(item.value)];
YCYRecordedWrite *捕获 = 项目;
[alert addAction:[ UIAlertAction actionWithTitle:title
样式： UIAlertActionStyleDestructive
处理程序:^( UIAlertAction *a) {
（ 空 ）a；
YCYTryUnlockWithBurst(@[captured], NO );
}]];
idx++;
}
[alert addAction:[ UIAlertAction actionWithTitle: @"关闭"
样式： UIAlertActionStyleCancel
处理程序： nil ]];
[YCYTopVC() presentViewController:alert animated: YES completion: nil ];
});
}

static void YCYCopyLogs( void ) {
[bleLogLock 锁定]；
UIPasteboard.generalPasteboard.string = [bleLogs componentsJoinedByString: @"\n" ];
[bleLogLock 解锁]；
YCYShowToast( @"日志已复制" );
}

static void YCYClearLogs( void ) {
[bleLogLock 锁定]；
[bleLogs removeAllObjects];
[bleLogLock 解锁]；
YCYLog( @"日志已清除" );
YCYShowToast( @"日志已清空" );
}

static void YCYClearRecords( void ) {
如果 (gFreezeBlock) {
dispatch_block_cancel(gFreezeBlock);
gFreezeBlock = nil ；
}
[recordLock 锁定]；
[canonicalWrites removeAllObjects];
[liveSession removeAllObjects];
[有效载荷计数移除所有对象]；
gCanonicalFrozen = 否 ；
[recordLock 解锁]；
NSUserDefaults *ud = [ NSUserDefaults standardUserDefaults];
[ud removeObjectForKey:kYCYRecordsKey];
[ud removeObjectForKey:kYCYRecordsKeyV2];
[ud setBool: NO forKey: @"YCYUnlock.frozen" ];
[ud 同步]；
YCYLog( @"记录已清除 — 等待下一次官方开锁以捕获唯一包" );
YCYShowToast( @"已清空。请控让方再开锁一次\n 插件仅保存唯一密文" );
}

# pragma mark - 悬浮窗

@interface YCYOverlayWindow : UIWindow
@结尾

@implementation YCYOverlayWindow
- ( UIView *)hitTest:( CGPoint )point withEvent:( UIEvent *)event {
UIView *hitView = [ super hitTest:point withEvent:event];
如果 (hitView == self || hitView == self.rootViewController.view ) 返回 nil ；
返回 hitView；
}
@结尾

static void YCYShowMenu( UIButton *sender) {
NSArray *canon = YCYCanonicalCopy();
NSArray *unique = YCYUniqueUnlockPackets(canon);
NSString *msg = [ NSString stringWithFormat:
@"按：开锁（原始优先 / 自动重连）\n 长按：本菜单\nv%@ 监控：%@\n 唯一包：%lu 原始：%lu%@\n 已连接：%lu" ,
kYCY 版本，
监控已启用？ @"开" : @"关" ,
( 无符号长整型 )唯一计数，
（ 无符号长整型 ）canon.count，
gCanonicalFrozen ？ @"（已坐在）" : @"" ,
( unsigned long )YCYConnectedPeripherals().count];

UIAlertController *menu =
[ UIAlertController alertControllerWithTitle: @"YCY 解锁"
消息:msg
preferredStyle: UIAlertControllerStyleActionSheet ];

[menu addAction:[ UIAlertAction actionWithTitle: @"仅调用 DCBLEManager 开锁"
样式： UIAlertActionStyleDestructive
处理程序:^( UIAlertAction *a) {
（ 空 ）a；
如果 (YCYTryNativeOpen()) {
YCYShowToast( @"已调用 DCBLEManager" );
} 别的 {
YCYShowToast( @"没匹配到方法，请复制日志" );
}
}]];
[menu addAction:[ UIAlertAction actionWithTitle: @"仅重放唯一 BLE 包"
样式： UIAlertActionStyleDefault
处理程序:^( UIAlertAction *a) {
（ 空 ）a；
YCYTryUnlockWithBurst( nil , NO );
}]];
[menu addAction:[ UIAlertAction actionWithTitle: @"仅触发 App 内部开锁"
样式： UIAlertActionStyleDefault
处理程序:^( UIAlertAction *a) {
（ 空 ）a；
如果 (YCYTryJSOpen()) {
YCYShowToast( @"已调用 App 内部开锁接口" );
} 别的 {
YCYShowToast( @"没找到_ble_do，请看日志里的 JS 探针" );
}
}]];
[menu addAction:[ UIAlertAction actionWithTitle: @"查看已记录指令"
样式： UIAlertActionStyleDefault
处理程序:^( UIAlertAction *a) {
（ 空 ）a；
YCYShowRecords();
}]];
[menu addAction:[ UIAlertAction actionWithTitle: @"查看 BLE 日志"
样式： UIAlertActionStyleDefault
处理程序:^( UIAlertAction *a) {
（ 空 ）a；
YCYShowLogs();
}]];
[menu addAction:[ UIAlertAction actionWithTitle: @"复制 BLE 日志"
样式： UIAlertActionStyleDefault
处理程序:^( UIAlertAction *a) {
（ 空 ）a；
YCYCopyLogs();
}]];
[菜单 addAction：[ UIAlertAction actionWithTitle： @“清空日志”
样式： UIAlertActionStyleDefault
处理程序:^( UIAlertAction *a) {
（ 空 ）a；
YCYClearLogs();
}]];
[menu addAction:[ UIAlertAction actionWithTitle: @"重新捕获（清空后等官方开锁）"
样式： UIAlertActionStyleDefault
处理程序:^( UIAlertAction *a) {
（ 空 ）a；
YCYClearRecords();
}]];
[菜单 addAction:[ UIAlertAction
actionWithTitle：监视器已启用？ @"关闭监控" : @"开启监控"
样式： UIAlertActionStyleDefault
处理程序:^( UIAlertAction *a) {
（ 空 ）a；
monitorEnabled = !monitorEnabled;
YCYLog( @"Monitor %@" , monitorEnabled ? @"enabled" : @"disabled" );
YCYShowToast(monitorEnabled ? @"监控已开启" : @"监控已关闭" );
}]];
[menu addAction:[ UIAlertAction actionWithTitle: @"取消"
样式： UIAlertActionStyleCancel
处理程序： nil ]];

如果 (menu.popoverPresentationController) {
menu.popoverPresentationController.sourceView = sender?:floatButton;
menu.popoverPresentationController.sourceRect = sender.bounds;
}
[YCYTopVC() presentViewController:menu animated: YES completion: nil ];
}

@implementation YCYUnlockHelper

+ ( 实例类型 )共享{
static YCYUnlockHelper *inst;
static dispatch_once_t once;
dispatch_once (&once, ^{ inst = [YCYUnlockHelper new]; });
返回实例；
}

- ( void )onTap {
YCYTryUnlock();
}

- ( void )onLongPress:( UILongPressGestureRecognizer *)g {
如果 (g.state == UIGestureRecognizerStateBegan ) {
YCYShowMenu(floatButton);
}
}

- ( void )onPan:( UIPanGestureRecognizer *)g {
UIView *v = floatButton;
CGPoint t = [g translationInView:v.superview];
v.center = CGPointMake (v.center.x + tx, v.center.y + ty);
[g setTranslation: CGPointZero inView:v.superview];

CGRect b = v.superview.bounds;
CGRect f = v.frame;
如果 ( CGRectGetMinX (f) < 0 ) f.origin.x = 0 ;
如果 ( CGRectGetMinY (f) < 80 ) f.origin.y = 80 ;
如果 ( CGRectGetMaxX (f) > b.size.width) f.origin.x = b.size.width - f.size.width;
如果 ( CGRectGetMaxY (f) > b.size.height - 40 ) f.origin.y = b.size.height - f.size.height - 40 ;
v.frame = f;
}

- ( void )observeValueForKeyPath: (NSString *)keyPath
ofObject:( id )对象
change:( NSDictionary < NSKeyValueChangeKey , id > *)change
context:( void *)context {
如果 (context != kYCYStateObs) {
[ super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
返回 ;
}
如果 (![object isKindOfClass:[CBPeripheral class ]]) 返回 ；
CBPeripheral *p = (CBPeripheral *)object;
NSInteger state = p.state;
YCYLog( @"外设状态变化 name=%@ state=%ld" , YCYPeripheralName(p), ( long )state);
如果 （状态 == CBPeripheralStateDisconnected ||
state == CBPeripheralStateConnecting) {
gNeedsRediscover = 是 ；
如果 (lastAppPeripheral == p) lastAppPeripheral = nil ;
}
如果 (state == CBPeripheralStateConnected) {
gNeedsRediscover = 是 ；
gSessionGen += 1 ;
gHandshakeWritesLeft = 3 ;
gHandshakeUntil = [ NSDate dateWithTimeIntervalSinceNow: 6.0 ];
}
}

@结尾

static void YCYCreateFloatingButton( void ) {
dispatch_async (dispatch_get_main_queue(), ^{
如果 (floatWindow) {
floatWindow.hidden = NO ;
如果 (floatButton) floatButton.hidden = NO ;
返回 ;
}

UIScreen *screen = [ UIScreen mainScreen];
floatWindow = [[YCYOverlayWindow alloc] initWithFrame:screen.bounds];
floatWindow.windowLevel = UIWindowLevelAlert + 100 ;
floatWindow.backgroundColor = [ UIColor clearColor];
floatWindow.opaque = NO ;
如果 (@available(iOS 13.0 , *)) {
for ( UIScene *scene in [ UIApplication sharedApplication].connectedScenes) {
如果 （[场景是 UIWindowScene 类 ]] &&
scene.activationState == UISceneActivationStateForegroundActive ) {
floatWindow.windowScene = ( UIWindowScene *)scene;
休息 ;
}
}
}

UIViewController *vc = [ UIViewController new];
vc.view.backgroundColor = [ UIColor clearColor];

floatButton = [ UIButton buttonWithType: UIButtonTypeCustom ];
floatButton.frame = CGRectMake (screen.bounds.size.width - 86 , 180 , 70 , 70 );
floatButton.backgroundColor = [[ UIColor systemRedColor] colorWithAlphaComponent: 0.92 ];
[floatButton setTitle: @"开锁" forState: UIControlStateNormal ];
[floatButton setTitleColor:[ UIColor whiteColor] forState: UIControlStateNormal ];
floatButton.titleLabel.font = [ UIFont boldSystemFontOfSize: 16 ];
floatButton.layer.cornerRadius = 35 ;
floatButton.layer.masksToBounds = NO ;
floatButton.layer.shadowOpacity = 0.35 ;
floatButton.layer.shadowRadius = 6 ;
floatButton.layer.shadowOffset = CGSizeMake ( 0 , 3 );

[floatButton addTarget:[YCYUnlockHelper shared]
操作： @selector （点击）
forControlEvents: UIControlEventTouchUpInside ];

UIPanGestureRecognizer *pan =
[[ UIPanGestureRecognizer alloc] initWithTarget:[YCYUnlockHelper 共享]
操作： @selector （onPan:）]；
[floatButton addGestureRecognizer:pan];

UILongPressGestureRecognizer *lp =
[[ UILongPressGestureRecognizer alloc] initWithTarget:[YCYUnlockHelper shared]
操作： @selector （onLongPress：）]；
lp.minimumPressDuration = 0.45 ;
[floatButton addGestureRecognizer:lp];

[vc.view addSubview:floatButton];
floatWindow.rootViewController = vc;
floatWindow.hidden = NO ;
YCYLog( @"浮动解锁按钮已创建" );
});
}

static void YCYScheduleFloatingButton( void ) {
static dispatch_once_t onceToken;
dispatch_once (&onceToken, ^{
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)( 2 * NSEC_PER_SEC )),
dispatch_get_main_queue(), ^{
YCYCreateFloatingButton();
});
});
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)( 0.6 * NSEC_PER_SEC )),
dispatch_get_main_queue(), ^{
YCYCreateFloatingButton();
});
}

# pragma mark - CoreBluetooth Monitor + 记录

%hook CBCentralManager

- ( 实例类型 )initWithDelegate: (id <CBCentralManagerDelegate>)delegate
队列:( dispatch_queue_t )队列
options:( NSDictionary *)options {
CBCentralManager *obj = %orig;
如果 (obj && delegate && ![delegate isKindOfClass:[YCYBleEngine class ]]) {
appCentral = obj;
}
返回对象；
}

- ( void )scanForPeripheralsWithServices:( NSArray <CBUUID *> *)serviceUUIDs
options:( NSDictionary < NSString *, id > *)options {
if (![ self.delegate isKindOfClass:[YCYBleEngine class ]]) {
appCentral = 自身 ；
}
如果 （监视器已启用）{
NSMutableArray *uuids = [ NSMutableArray 数组];
for (CBUUID *uuid in serviceUUIDs) [uuids addObject:uuid.UUIDString];
YCYLog( @"扫描服务=%@选项=%@" , uuids, options);
}
%orig;
}

- ( void )stopScan {
如果 (monitorEnabled && ![ self.delegate isKindOfClass:[YCYBleEngine class ]]) {
YCYLog( @"stopScan" );
}
%orig;
}

- ( void )connectPeripheral:(CBPeripheral *)peripheral
options:( NSDictionary < NSString *, id > *)options {
YCYRememberPeripheral(外设);
gNeedsRediscover = 是 ；
gSessionGen += 1 ;
gHandshakeWritesLeft = 3 ;
gHandshakeUntil = [ NSDate dateWithTimeIntervalSinceNow: 6.0 ];
if (![ self.delegate isKindOfClass:[YCYBleEngine class ]]) {
appCentral = 自身 ；
}
如果 （监视器已启用）{
YCYLog( @"连接名称=%@ UUID=%@" ,
YCYPeripheralName(外围设备)
YCYUUIDString(外设标识符));
}
%orig;
}

- ( void )cancelPeripheralConnection:(CBPeripheral *)peripheral {
gNeedsRediscover = 是 ；
如果 (lastAppPeripheral == peripheral) lastAppPeripheral = nil ;
如果 （监视器已启用）{
YCYLog( @"取消连接 name=%@ UUID=%@" ,
YCYPeripheralName(外围设备)
YCYUUIDString(外设标识符));
}
%orig;
}

- ( NSArray *)retrieveConnectedPeripheralsWithServices:( NSArray *)serviceUUIDs {
NSArray *result = %orig;
for (CBPeripheral *p in result) YCYRememberPeripheral(p);
返回结果；
}

％结尾

%hook CBPeripheral

- ( void )setDelegate:( id <CBPeripheralDelegate>)delegate {
YCYRememberPeripheral( self );
如果 （委托）YCYRememberDCBLE（委托）；
如果 （监视器已启用）{
YCYLog( @"%@ setDelegate class=%@" ,
YCYPeripheralName( self ),
delegate ? NSStringFromClass ([delegate class ]) : @"<nil>" );
}
%orig;
}

- ( void )discoverServices:( NSArray <CBUUID *> *)serviceUUIDs {
YCYRememberPeripheral( self );
如果 （监视器已启用）{
NSMutableArray *uuids = [ NSMutableArray 数组];
for (CBUUID *uuid in serviceUUIDs) [uuids addObject:uuid.UUIDString];
YCYLog( @"%@ discoverServices=%@" , YCYPeripheralName( self ), uuids);
}
%orig;
}

- ( void )discoverCharacteristics:( NSArray *)characteristicUUIDs
forService:(CBService *)服务 {
如果 （监视器已启用）{
NSMutableArray *uuids = [ NSMutableArray 数组];
for (CBUUID *uuid in characteristicUUIDs) [uuids addObject:uuid.UUIDString];
YCYLog( @"%@ discoverCharacteristics service=%@ chars=%@" ,
YCYPeripheralName( self ),
service.UUID.UUIDString，
uuids）；
}
%orig;
}

- ( void )readValueForCharacteristic:(CBCharacteristic *)characteristic {
如果 （监视器已启用）{
YCYLog( @"%@ READ service=%@ char=%@" ,
YCYPeripheralName( self ),
characteristic.service.UUID.UUIDString,
特征.UUID.UUIDString);
}
%orig;
}

- ( void )setNotifyValue:( BOOL )enabled forCharacteristic:(CBCharacteristic *)characteristic {
如果 （监视器已启用）{
YCYLog( @"%@ NOTIFY %@ service=%@ char=%@" ,
YCYPeripheralName( self ),
已启用？ @"开启" : @"关闭" ,
characteristic.service.UUID.UUIDString,
特征.UUID.UUIDString);
}
%orig;
}

- ( void )writeValue:( NSData *)data
forCharacteristic:(CBCharacteristic *)characteristic
类型:(CBCharacteristicWriteType)类型 {
YCYRememberPeripheral( self );

如果 （监视器已启用）{
NSString *writeType = (type == CBCharacteristicWriteWithResponse)
? @"WithResponse" : @"WithoutResponse" ;
YCYLog( @"%@ WRITE service=%@ char=%@ props=[%@] type=%@ len=%lu HEX=%@" ,
YCYPeripheralName( self ),
characteristic.service.UUID.UUIDString,
特征.UUID.UUIDString，
YCYProperties（特征），
writeType，
( 无符号长整型 )数据.长度，
YCYHexString(data));
}

YCYRecordWrite( self , characteristic, data, type);
%orig;
}

％结尾

# pragma mark - JSContext

%hook JSContext

- (JSValue *)evaluateScript:( NSString *)script {
YCYRememberJSContext( self );
返回 %orig；
}

- (JSValue *)evaluateScript:( NSString *)script withSourceURL:( NSURL *)sourceURL {
YCYRememberJSContext( self );
返回 %orig；
}

％结尾

# pragma mark - 应用程序生命周期

%hook UIApplication

- ( BOOL )application:( UIApplication *)application
didFinishLaunchingWithOptions:( NSDictionary *)launchOptions {
YCYInitState();
YCYLog( @"didFinishLaunching" );
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)( 3 * NSEC_PER_SEC )),
dispatch_get_main_queue(), ^{
YCYDumpInterestingClasses();
});
BOOL result = %orig(application, launchOptions);
YCYScheduleFloatingButton();
返回结果；
}

- ( void )applicationDidBecomeActive:( UIApplication *)application {
YCYInitState();
YCYLog( @"applicationDidBecomeActive" );
%orig;
YCYScheduleFloatingButton();
}

％结尾

%hook UIWindow

- ( void )makeKeyAndVisible {
%orig;
YCYScheduleFloatingButton();
}

％结尾

%ctor {
YCYInitState();
YCYLog( @"================================" );
YCYLog( @"YCYUnlock 已加载 v%@" , kYCYVersion);
YCYLog( @"断电后禁止盲放旧密文，自动通过 appCentral 重连并触发 DCBLEManager" );
YCYLog( @"短按 = 间隙开锁 / 状态检测重连" );
YCYLog( @"长按=菜单/转储" );
YCYLog( @"================================" );
YCYScheduleFloatingButton();
}
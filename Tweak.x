#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <QuartzCore/QuartzCore.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <objc/runtime.h>

/*
 * YCYUnlock v1.3.1
 *
 * 日志结论（断电失败）：
 * - 握手是：WRITE 13 35…（跨会话不变）→ NOTIFY 挑战 → WRITE 4B 58… + 9B 17…（会话密文）
 * - v1.2 把握手后两包冻成「开锁」，同连接重放能收到通知；断电后挑战变了，旧密文被锁忽略（无 NOTIFY）
 * - JS _ble_do 不在全局（miss）；原生类是 DCBLEManager
 *
 * v1.3：短按优先调 DCBLEManager 让 App 用当前会话密钥开锁。
 * 断电后用 App 自己的 CBCentralManager 重连（不抢 delegate），禁止 YCYBleEngine 盲放旧密文。
 *
 * v1.3.1 修复：
 * - gDCBLE 主动探测（不依赖 setDelegate hook 恰好捕获到 DCBLEManager）
 * - 重连改为优先触发 DCBLEManager 自身重扫，兜底才走 appCentral
 * - 会话代际 gSessionGen 改为「握手完成（NOTIFY 挑战到达）」时递增
 * - 新增 gSessionKeyReady 标志，sameSession 判断必须密钥就绪
 * - DCBLEManager 开锁方法增加模糊匹配回退
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
static BOOL gSessionKeyReady = NO;
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

#pragma mark - DCBLE 实例探测 / 模糊开锁

static void YCYProbeDCBLEInstances(void) {
    YCYInitState();

    Class dc = NSClassFromString(@"DCBLEManager");
    if (!dc) {
        YCYLog(@"[probe] 未找到 DCBLEManager 类");
        return;
    }

    // 1. 尝试所有可能的共享实例方法
    NSArray *sharedSelectors = @[
        @"shared", @"sharedInstance", @"sharedManager",
        @"defaultManager", @"singleton", @"instance",
        @"getInstance", @"manager", @"managerInstance"
    ];
    for (NSString *sel in sharedSelectors) {
        SEL s = NSSelectorFromString(sel);
        if ([dc respondsToSelector:s]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id inst = [dc performSelector:s];
            #pragma clang diagnostic pop
            if (inst && inst != (id)dc) {
                YCYLog(@"[probe] 通过 +%@ 获取 DCBLEManager 实例", sel);
                YCYRememberDCBLE(inst);
                return;
            }
        }
    }

    // 2. 从 appCentral 的 delegate 链中寻找
    if (appCentral && appCentral.delegate) {
        id del = appCentral.delegate;
        YCYLog(@"[probe] appCentral delegate = %@", NSStringFromClass([del class]));
        YCYRememberDCBLE(del);
        if (gDCBLE) return;
    }

    // 3. 从 lastAppPeripheral 的 delegate 中寻找
    if (lastAppPeripheral && lastAppPeripheral.delegate) {
        id del = lastAppPeripheral.delegate;
        YCYLog(@"[probe] lastAppPeripheral delegate = %@", NSStringFromClass([del class]));
        YCYRememberDCBLE(del);
        if (gDCBLE) return;
    }

    // 4. 全局搜索已注册的 BLE 管理器实例（兜底）
    if (!gDCBLE) {
        YCYLog(@"[probe] 未获取到 DCBLEManager 实例（后续 setDelegate hook 仍有机会捕获）");
    } else {
        YCYLog(@"[probe] DCBLE 实例探测完成，gDCBLE=%@",
               NSStringFromClass([gDCBLE class]));
    }
}

static BOOL YCYTryNativeOpenFuzzy(void) {
    id mgr = gDCBLE;
    if (!mgr) return NO;

    Class cls = [mgr class];
    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    if (!ms) return NO;

    BOOL didAny = NO;
    for (unsigned int i = 0; i < n; i++) {
        SEL sel = method_getName(ms[i]);
        NSString *name = NSStringFromSelector(sel);
        NSUInteger nargs = method_getNumberOfArguments(ms[i]) - 2;
        if (nargs > 2) continue;
        // 排除明显的非动作方法
        if ([name hasPrefix:@"set"] || [name hasPrefix:@"get"] ||
            [name hasPrefix:@"is"]  || [name hasPrefix:@"init"] ||
            [name hasPrefix:@"_"] || [name hasPrefix:@"."]) {
            continue;
        }
        BOOL key = ([name localizedCaseInsensitiveContainsString:@"open"] ||
                    [name localizedCaseInsensitiveContainsString:@"unlock"] ||
                    [name localizedCaseInsensitiveContainsString:@"do"] ||
                    [name localizedCaseInsensitiveContainsString:@"send"]);
        if (!key) continue;

        if (nargs == 0) {
            if (YCYInvoke(mgr, name, nil)) {
                YCYLog(@"模糊匹配零参调用: %@", name);
                didAny = YES;
                break;
            }
        } else if (nargs == 1) {
            NSArray *args = @[
                @"open",
                @{@"type": @"open"},
                @{@"action": @"open"},
                @{@"cmd": @"open"},
                @{@"command": @"open"}
            ];
            for (id a in args) {
                if (YCYInvoke(mgr, name, a)) {
                    YCYLog(@"模糊匹配单参调用: %@", name);
                    didAny = YES;
                    break;
                }
            }
            if (didAny) break;
        }
    }
    if (ms) free(ms);
    return didAny;
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
        @"openDevice", @"unlockDevice", @"openAction"
    ];
    for (NSString *s in zeroArg) {
        if (YCYInvoke(mgr, s, nil)) return YES;
    }

    NSArray *oneArg = @[
        @"open:", @"unlock:", @"openLock:", @"bleOpen:", @"doOpen:",
        @"sendOpen:", @"bleUnlock:", @"_init_ble:", @"initBle:",
        @"ble_do:", @"bleDo:", @"sendCommand:", @"sendCmd:",
        @"writeCommand:", @"openWithType:", @"openType:",
        @"setAction:", @"doAction:", @"execute:"
    ];
    NSArray *args = @[
        @"open",
        @{@"type": @"open", @"action": @"open", @"cmd": @"open"},
        @{@"command": @"open"}
    ];
    for (NSString *s in oneArg) {
        for (id a in args) {
            if (YCYInvoke(mgr, s, a)) return YES;
        }
    }

    // 硬编码没命中 → 模糊匹配兜底
    YCYLog(@"硬编码列表未命中，尝试模糊匹配 DCBLEManager 开锁方法");
    if (YCYTryNativeOpenFuzzy()) return YES;

    YCYLog(@"DCBLEManager 没有匹配到开锁方法，请看上面的 dump 列表");
    return NO;
}

#pragma mark - App 重扫 / 重连

static BOOL YCYTriggerAppRescan(void) {
    id mgr = gDCBLE;
    if (mgr) {
        NSArray *rescanSelectors = @[
            @"startScan", @"startScanning", @"scanForDevices",
            @"reconnect", @"reconnectDevice", @"connectDevice",
            @"autoConnect", @"restartScan", @"beginScan",
            @"resumeScan", @"rescan", @"searchDevice", @"search"
        ];
        for (NSString *sel in rescanSelectors) {
            if (YCYInvoke(mgr, sel, nil)) {
                YCYLog(@"已触发 DCBLEManager 重扫: %@", sel);
                return YES;
            }
        }
        YCYLog(@"DCBLEManager 没有匹配到重扫方法");
    }

    if (appCentral && appCentral.state == CBManagerStatePoweredOn) {
        YCYLog(@"通过 appCentral 扫描，让 App 自己发现锁盒");
        [appCentral scanForPeripheralsWithServices:nil
                                           options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
        return YES;
    }
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

#pragma mark - 握手通知 / 会话就绪

static NSDate *gLastHandshakeNotify = nil;

static void YCYOnNotificationReceived(CBPeripheral *peripheral,
                                       CBCharacteristic *characteristic,
                                       NSData *value) {
    if (!characteristic) return;
    if (!YCYIsTargetCharacteristic(characteristic.UUID.UUIDString)) return;

    NSTimeInterval sinceLast = gLastHandshakeNotify
        ? -[gLastHandshakeNotify timeIntervalSinceNow] : 999.0;
    if (sinceLast < 3.0) return;

    gLastHandshakeNotify = [NSDate date];
    gSessionGen += 1;
    gSessionKeyReady = YES;
    gHandshakeWritesLeft = 0;
    gHandshakeUntil = nil;

    YCYLog(@"★ 检测到握手通知（会话密钥就绪），sessionGen=%lu name=%@ char=%@ HEX=%@",
           (unsigned long)gSessionGen,
           YCYPeripheralName(peripheral),
           characteristic.UUID.UUIDString,
           YCYShortHex(value));
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
    gSessionKeyReady = NO;
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
    YCYOnNotificationReceived(peripheral, characteristic, characteristic.value);
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

    // 每次尝试开锁都刷新一次 DCBLE 实例探测（App 可能刚刚重建过管理器）
    if (!gDCBLE) YCYProbeDCBLEInstances();

    NSArray *connected = YCYConnectedPeripherals();
    CBPeripheral *ready = YCYPickPeripheral(connected, lastLockUUID);
    BOOL appConnected = ready && ready.state == CBPeripheralStateConnected;
    NSTimeInterval sinceWrite = lastAppWriteTime ? -[lastAppWriteTime timeIntervalSinceNow] : 999;
    BOOL sameSession = appConnected
        && !gNeedsRediscover
        && sinceWrite < 15.0
        && gSessionKeyReady
        && (gFrozenSessionGen == 0 || gFrozenSessionGen == gSessionGen);

    YCYLog(@"尝试开锁 connected=%lu sameSession=%d(ready=%d gen=%lu/%lu) frozen=%d js=%d native=%@",
           (unsigned long)connected.count,
           sameSession,
           gSessionKeyReady,
           (unsigned long)gFrozenSessionGen,
           (unsigned long)gSessionGen,
           gCanonicalFrozen,
           tryJS,
           gDCBLE ? NSStringFromClass([gDCBLE class]) : @"nil");

    gUnlockInFlight = YES;
    YCYSetButtonBusy(YES);

    /* 1) 原生 DCBLEManager：让 App 用当前会话密钥组包。断电后这是唯一靠谱的路。 */
    if (YCYTryNativeOpen()) {
        YCYShowToast(@"已调用 DCBLEManager 开锁");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YCYFinishUnlockFlight();
        });
        return;
    }

    /* 2) JS 兜底（_ble_do 目前不在全局，但万一以后暴露了） */
    if (tryJS && YCYTryJSOpen()) {
        YCYShowToast(@"已调用 App 内部 JS 开锁");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YCYFinishUnlockFlight();
        });
        return;
    }

    /* 3) 未连接 / 会话不新鲜：让 App 自己重连（优先触发 DCBLEManager 重扫） */
    BOOL needReconnect = !appConnected || !gSessionKeyReady;
    if (needReconnect) {
        YCYLog(@"会话不可用（connected=%d keyReady=%d），触发 App 重连", appConnected, gSessionKeyReady);
        BOOL triggered = YCYTriggerAppRescan();
        if (!triggered) {
            // DCBLEManager 重扫不可用，回退 appCentral 扫描
            triggered = YCYConnectViaAppCentral();
        }
        if (triggered) {
            YCYShowToast(@"锁盒断电后旧密文无效\n正在让 App 重连，随后再调原生开锁");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (YCYTryNativeOpen()) {
                    YCYShowToast(@"重连后已调用 DCBLEManager");
                } else {
                    YCYShowToast(@"重连后仍没找到开锁方法\n请复制日志发回来（看 DCBLE dump）");
                }
                YCYFinishUnlockFlight();
            });
            return;
        }
        YCYFinishUnlockFlight();
        YCYShowToast(@"无法触发 App 重连\n请先打开役次元蓝牙页再试");
        return;
    }

    /* 4) 仍是同一会话才允许 BLE 重放。跨连接/断电后的密文一律不放。 */
    if (!sameSession) {
        YCYLog(@"会话已变，拒绝重放旧密文 needsRediscover=%d sinceWrite=%.1f keyReady=%d",
               gNeedsRediscover, sinceWrite, gSessionKeyReady);
        YCYFinishUnlockFlight();
        YCYShowToast(@"当前是新连接，旧密文已失效\n已尝试原生开锁但没匹配到方法\n请复制日志（DCBLE dump）");
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
        YCYShowToast(@"同一会话内也没有可重放的包\n原生方法没匹配到，请发日志");
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
        @"短按：开锁（原生优先，否则重放唯一密文）\n长按：本菜单\nv%@  监控：%@\n唯一包：%lu  原始：%lu%@\n已连接：%lu  会话就绪：%@",
        kYCYVersion,
        monitorEnabled ? @"开" : @"关",
        (unsigned long)unique.count,
        (unsigned long)canon.count,
        gCanonicalFrozen ? @"（已冻结）" : @"",
        (unsigned long)YCYConnectedPeripherals().count,
        gSessionKeyReady ? @"是" : @"否"];

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
    [menu addAction:[UIAlertAction actionWithTitle:@"重新探测 DCBLE 实例"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
                                               (void)a;
                                               YCYProbeDCBLEInstances();
                                               YCYShowToast(gDCBLE
                                                   ? [NSString stringWithFormat:@"gDCBLE=%@",
                                                      NSStringFromClass([gDCBLE class])]
                                                   : @"未探测到 DCBLE 实例");
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
        gSessionKeyReady = NO;
        if (lastAppPeripheral == p) lastAppPeripheral = nil;
    }
    if (state == CBPeripheralStateConnected) {
        gNeedsRediscover = YES;
        /* 连接建立 ≠ 密钥就绪。仅设置握手窗口；sessionGen 由 NOTIFY 挑战递增。 */
        gHandshakeWritesLeft = 3;
        gHandshakeUntil = [NSDate dateWithTimeIntervalSinceNow:6.0];
        /* 连接变了，旧会话密钥作废，等待下一次握手通知 */
        gSessionKeyReady = NO;
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
        YCYRememberDCBLE(delegate);
    }
    return obj;
}

- (void)scanForPeripheralsWithServices:(NSArray<CBUUID *> *)serviceUUIDs
                               options:(NSDictionary<NSString *,id> *)options {
    if (![self.delegate isKindOfClass:[YCYBleEngine class]]) {
        appCentral = self;
        YCYRememberDCBLE(self.delegate);
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
    gHandshakeWritesLeft = 3;
    gHandshakeUntil = [NSDate dateWithTimeIntervalSinceNow:6.0];
    /* 连接刚发出，密钥尚未协商 */
    gSessionKeyReady = NO;
    if (![self.delegate isKindOfClass:[YCYBleEngine class]]) {
        appCentral = self;
        YCYRememberDCBLE(self.delegate);
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
    gSessionKeyReady = NO;
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

#pragma mark - CBPeripheralDelegate 通知（App 路径）

/*
 * App 自己的 CBPeripheralDelegate 收到通知时，我们需要把握手挑战回传进 YCYOnNotificationReceived，
 * 否则 gSessionGen / gSessionKeyReady 只会被 YCYBleEngine 的 delegate 更新。
 *
 * 由于 delegate 是外部对象，这里 hook 通用的 setNotifyValue / didUpdateValueForCharacteristic
 * 无法直接拦到 App 的 delegate 回调，因此我们退一步：
 * 在 CBCharacteristic 的 -setValue: 上做一次兜底（App 收到通知后 CoreBluetooth 会 setValue）。
 */

%hook CBCharacteristic

- (void)setValue:(NSData *)value {
    %orig;
    if (value && YCYIsTargetCharacteristic(self.UUID.UUIDString)) {
        YCYOnNotificationReceived(self.service.peripheral, self, value);
    }
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
        YCYProbeDCBLEInstances();
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
    if (!gDCBLE) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YCYProbeDCBLEInstances();
        });
    }
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
    YCYLog(@"断电后禁止盲放旧密文，走 DCBLEManager");
    YCYLog(@"短按 = 原生开锁 / App 重连");
    YCYLog(@"长按 = 菜单 / dump");
    YCYLog(@"==============================");
    YCYScheduleFloatingButton();
}

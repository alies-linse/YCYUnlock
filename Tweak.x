#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <QuartzCore/QuartzCore.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <objc/runtime.h>

/*
 * YCYUnlock v1.6.0
 *
 * v1.5 已打通：retrieve + 6参 connect → state=2，JS uni.createBLEConnection 成功。
 * 真正开锁入口是 JS _ble_do（trap 已命中 opened:trap_ble_do）。
 * 但断电重连后立刻 _ble_do 会写出捕获时的旧密文，App 随后 cancelConnect。
 * 业务层在 libBlueTooth（PGPlugin）：createBLEConnection / writeBLECharacteristicValue /
 * notifyBLECharacteristicValueChange。DCBLEManager 没有 open。
 *
 * v1.6：连上先开 notify + _init_ble / 握手首包，等本会话新 NOTIFY，再 _ble_do。
 * 开锁进行中拦截 cancelConnect。
 */

#pragma mark - 常量（YS04 / Walkiz）

static NSString * const kYCYChar9001 = @"00009001-0000-1000-8000-57616C6B697A";
static NSString * const kYCYChar9002 = @"00009002-0000-1000-8000-57616C6B697A";
static NSString * const kYCYCharAE01 = @"AE01";
static NSString * const kYCYCharAE02 = @"AE02";
static NSString * const kYCYSvc9000  = @"00009000-0000-1000-8000-57616C6B697A";
static NSString * const kYCYSvcAE00  = @"AE00";
static NSString * const kYCYRecordsKey = @"YCYUnlock.canonicalWrites.v4";
static NSString * const kYCYRecordsKeyV3 = @"YCYUnlock.canonicalWrites.v3";
static NSString * const kYCYRecordsKeyV2 = @"YCYUnlock.canonicalWrites.v2";
static NSString * const kYCYLockUUIDKey = @"YCYUnlock.lastLockUUID";
static NSString * const kYCYLockNameKey = @"YCYUnlock.lastLockName";
static NSString * const kYCYHelloKey = @"YCYUnlock.helloHex";
static NSString * const kYCYHelloCharKey = @"YCYUnlock.helloChar";
static NSString * const kYCYVersion = @"1.6.1";

static const NSInteger kYCYHandshakeWrites = 5;
static const NSTimeInterval kYCYHandshakeSeconds = 8.0;
static const NSTimeInterval kYCYFreezeIdle = 2.0;
static const NSTimeInterval kYCYUnlockCluster = 0.85;

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
static BOOL gCaptureArmed = NO;
static BOOL gHeartbeatSeen = NO;
static BOOL gSawDiscoverChars = NO;
static BOOL gDidDiscoverServices = NO;
static NSUInteger gDiscoveredCharacteristicCount = 0;
static BOOL gDCBLENotifyHooked = NO;
static BOOL gDCBLEDiscoverHooked = NO;
static BOOL gSessionNotifySeen = NO;
static BOOL gSessionHandshakeWrite = NO;
static BOOL gDidPostConnect = NO;
static BOOL gDidJSOpenThisFlight = NO;
static NSData *gHelloPayload;
static NSString *gHelloCharUUID;
static NSDate *gHandshakeUntil;
static NSInteger gHandshakeWritesLeft = 0;
static NSUInteger gSessionGen = 0;
static NSUInteger gFrozenSessionGen = 0;
static NSDate *gLastSessionNote;

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
static NSMutableArray<NSString *> *gDCBLEOpenSels;
static NSMutableArray<NSString *> *gDCBLEConnectSels;
static NSMutableSet<NSNumber *> *gJSContextTraps;

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
static void YCYInstallJSTrap(JSContext *ctx);
static void YCYNoteNewSession(NSString *reason);
static void YCYPollUnlockAfterReconnect(int attempts, BOOL tryJS);
static void YCYEnableNotifies(CBPeripheral *peripheral);
static BOOL YCYHasRequiredBLELayout(CBPeripheral *peripheral);

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
        gDCBLEOpenSels = [NSMutableArray array];
        gDCBLEConnectSels = [NSMutableArray array];
        gJSContextTraps = [NSMutableSet set];
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
    if (bleLogs.count > 800) {
        [bleLogs removeObjectsInRange:NSMakeRange(0, bleLogs.count - 800)];
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

static BOOL YCYNameLooksDangerous(NSString *name) {
    NSString *n = name.lowercaseString;
    if ([n containsString:@"close"] || [n containsString:@"disconnect"] ||
        [n containsString:@"cancel"] || [n containsString:@"stop"] ||
        [n containsString:@"hide"] || [n containsString:@"dealloc"] ||
        [n containsString:@"shutdown"] || [n containsString:@"reset"] ||
        [n containsString:@"remove"] || [n containsString:@"delete"] ||
        [n containsString:@"poweroff"] || [n containsString:@"lockdevice"]) {
        return YES;
    }
    if ([n containsString:@"lock"] && ![n containsString:@"unlock"] && ![n containsString:@"open"]) {
        return YES;
    }
    return NO;
}

static BOOL YCYNameLooksLikeOpen(NSString *name) {
    if (YCYNameLooksDangerous(name)) return NO;
    NSString *n = name.lowercaseString;
    if ([n containsString:@"adapter"] || [n containsString:@"bluetooth"]) return NO;
    if ([n containsString:@"unlock"] || [n containsString:@"un_lock"] ||
        [n containsString:@"bleopen"] || [n containsString:@"ble_open"] ||
        [n containsString:@"doopen"]) {
        return YES;
    }
    if ([n containsString:@"open"] && ![n containsString:@"openn"]) return YES;
    return NO;
}

static BOOL YCYNameLooksLikeConnect(NSString *name) {
    NSString *n = name.lowercaseString;
    if ([n containsString:@"disconnect"] || [n containsString:@"cancel"] ||
        [n containsString:@"fail"] || [n containsString:@"scan"] ||
        [n hasPrefix:@"centralmanager"]) {
        return NO;
    }
    if ([n containsString:@"connectperipheral"]) return YES;
    if ([n isEqualToString:@"connect"] || [n isEqualToString:@"connect:"]) return YES;
    return NO;
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
            [name localizedCaseInsensitiveContainsString:@"JSContext"] ||
            [name localizedCaseInsensitiveContainsString:@"Weex"] ||
            [name localizedCaseInsensitiveContainsString:@"WXJS"] ||
            [name localizedCaseInsensitiveContainsString:@"DCUni"] ||
            [name localizedCaseInsensitiveContainsString:@"UniJS"]) {
            if ([name hasPrefix:@"NS"] || [name hasPrefix:@"UI"] || [name hasPrefix:@"CB"] ||
                [name hasPrefix:@"WK"] || [name hasPrefix:@"JS"]) continue;
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

static void YCYCollectOpenSelectors(Class cls) {
    if (!cls) return;
    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        NSString *name = NSStringFromSelector(method_getName(ms[i]));
        if (YCYNameLooksLikeOpen(name) && ![gDCBLEOpenSels containsObject:name]) {
            [gDCBLEOpenSels addObject:name];
            YCYLog(@"候选开锁方法 %@", name);
        }
        if (YCYNameLooksLikeConnect(name) && ![gDCBLEConnectSels containsObject:name]) {
            [gDCBLEConnectSels addObject:name];
            YCYLog(@"候选连接方法 %@", name);
        }
    }
    if (ms) free(ms);
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
        if (YCYNameLooksLikeOpen(name) && ![gDCBLEOpenSels containsObject:name]) {
            [gDCBLEOpenSels addObject:name];
        }
        if (YCYNameLooksLikeConnect(name) && ![gDCBLEConnectSels containsObject:name]) {
            [gDCBLEConnectSels addObject:name];
        }
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
    YCYCollectOpenSelectors(cls);
}

static void (*YCYOrigNotify)(id, SEL, CBPeripheral *, CBCharacteristic *, NSError *) = NULL;

static void YCYHookedNotify(id self, SEL _cmd, CBPeripheral *p, CBCharacteristic *c, NSError *e) {
    if (monitorEnabled) {
        YCYLog(@"%@ NOTIFY char=%@ HEX=%@",
               YCYPeripheralName(p),
               c.UUID.UUIDString,
               YCYHexString(c.value));
    }
    if (c.value.length > 0) gSessionNotifySeen = YES;
    if (YCYOrigNotify) {
        YCYOrigNotify(self, _cmd, p, c, e);
    }
}

static void YCYHookDCBLENotify(Class cls) {
    if (gDCBLENotifyHooked || !cls) return;
    SEL sel = @selector(peripheral:didUpdateValueForCharacteristic:error:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        YCYLog(@"%@ 没有 didUpdateValue，无法 hook NOTIFY", NSStringFromClass(cls));
        return;
    }
    gDCBLENotifyHooked = YES;
    YCYOrigNotify = (void (*)(id, SEL, CBPeripheral *, CBCharacteristic *, NSError *))method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    if (!class_addMethod(cls, sel, (IMP)YCYHookedNotify, types)) {
        method_setImplementation(m, (IMP)YCYHookedNotify);
    }
    YCYLog(@"已 hook %@ NOTIFY", NSStringFromClass(cls));
}

static void (*YCYOrigDiscoverServices)(id, SEL, CBPeripheral *, NSError *) = NULL;
static void (*YCYOrigDiscoverChars)(id, SEL, CBPeripheral *, CBService *, NSError *) = NULL;

static void YCYHookedDiscoverServices(id self, SEL _cmd, CBPeripheral *p, NSError *e) {
    if (e) {
        YCYLog(@"发现服务失败 %@", e);
    } else {
        gDidDiscoverServices = (p.services.count > 0);
        YCYLog(@"发现服务完成 name=%@ count=%lu",
               YCYPeripheralName(p), (unsigned long)p.services.count);
    }
    if (YCYOrigDiscoverServices) {
        YCYOrigDiscoverServices(self, _cmd, p, e);
    }
}

static void YCYHookedDiscoverChars(id self, SEL _cmd, CBPeripheral *p, CBService *service, NSError *e) {
    if (e) {
        YCYLog(@"发现特征失败 service=%@ error=%@", service.UUID.UUIDString, e);
    } else {
        gDiscoveredCharacteristicCount += service.characteristics.count;
        gSawDiscoverChars = YES;
        YCYLog(@"发现特征完成 service=%@ count=%lu layout=%d",
               service.UUID.UUIDString,
               (unsigned long)service.characteristics.count,
               YCYHasRequiredBLELayout(p));
        if (YCYHasRequiredBLELayout(p)) {
            YCYEnableNotifies(p);
        }
    }
    if (YCYOrigDiscoverChars) {
        YCYOrigDiscoverChars(self, _cmd, p, service, e);
    }
}

static void YCYHookDCBLEDiscover(Class cls) {
    if (gDCBLEDiscoverHooked || !cls) return;
    BOOL hookedAny = NO;

    SEL svcSel = @selector(peripheral:didDiscoverServices:);
    Method svcM = class_getInstanceMethod(cls, svcSel);
    if (svcM) {
        YCYOrigDiscoverServices = (void (*)(id, SEL, CBPeripheral *, NSError *))method_getImplementation(svcM);
        const char *types = method_getTypeEncoding(svcM);
        if (!class_addMethod(cls, svcSel, (IMP)YCYHookedDiscoverServices, types)) {
            method_setImplementation(svcM, (IMP)YCYHookedDiscoverServices);
        }
        hookedAny = YES;
        YCYLog(@"已 hook %@ didDiscoverServices", NSStringFromClass(cls));
    }

    SEL charSel = @selector(peripheral:didDiscoverCharacteristicsForService:error:);
    Method charM = class_getInstanceMethod(cls, charSel);
    if (charM) {
        YCYOrigDiscoverChars = (void (*)(id, SEL, CBPeripheral *, CBService *, NSError *))method_getImplementation(charM);
        const char *types = method_getTypeEncoding(charM);
        if (!class_addMethod(cls, charSel, (IMP)YCYHookedDiscoverChars, types)) {
            method_setImplementation(charM, (IMP)YCYHookedDiscoverChars);
        }
        hookedAny = YES;
        YCYLog(@"已 hook %@ didDiscoverCharacteristics", NSStringFromClass(cls));
    }

    if (hookedAny) gDCBLEDiscoverHooked = YES;
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
    YCYHookDCBLENotify([obj class]);
    YCYHookDCBLEDiscover([obj class]);
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
        if (!t) return NO;
        if (t[0] == '@') {
            id a = arg;
            [inv setArgument:&a atIndex:2];
        } else if (t[0] == 'B' || t[0] == 'c' || t[0] == 'C') {
            unsigned char v = 1;
            [inv setArgument:&v atIndex:2];
        } else if (t[0] == 'i' || t[0] == 'I') {
            int v = 1;
            [inv setArgument:&v atIndex:2];
        } else if (t[0] == 'q' || t[0] == 'Q' || t[0] == 'l' || t[0] == 'L') {
            long long v = 1;
            [inv setArgument:&v atIndex:2];
        } else {
            YCYLog(@"跳过 %@ 参数类型 %s", selName, t);
            return NO;
        }
    }
    if (nargs >= 4) {
        const char *t = [sig getArgumentTypeAtIndex:3];
        if (t && t[0] == '@') {
            id a = arg;
            [inv setArgument:&a atIndex:3];
        } else {
            YCYLog(@"跳过 %@ 第2参类型 %s", selName, t ? t : "?");
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

static id YCYFindDCBLE(void) {
    id mgr = gDCBLE;
    if (!mgr) {
        CBPeripheral *p = lastAppPeripheral;
        if (p.delegate) mgr = p.delegate;
    }
    if (!mgr) {
        Class cls = NSClassFromString(@"DCBLEManager");
        if (cls) {
            YCYDumpClassDetailed(cls);
            for (NSString *s in @[@"shared", @"sharedInstance", @"sharedManager", @"defaultManager", @"singleton", @"manager"]) {
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
    if (mgr) YCYRememberDCBLE(mgr);
    return mgr;
}

static BOOL YCYTryNativeOpen(void) {
    id mgr = YCYFindDCBLE();
    if (!mgr) {
        YCYLog(@"没有 DCBLEManager 实例");
        return NO;
    }

    NSMutableArray *sels = [NSMutableArray array];
    [sels addObjectsFromArray:gDCBLEOpenSels];
    NSArray *zeroArg = @[
        @"open", @"unlock", @"openLock", @"bleOpen", @"doOpen",
        @"sendOpen", @"unLock", @"bleUnlock", @"openBox",
        @"openDevice", @"unlockDevice", @"openAction", @"clickOpen"
    ];
    for (NSString *s in zeroArg) {
        if (![sels containsObject:s]) [sels addObject:s];
    }
    for (NSString *s in sels) {
        if (![s hasSuffix:@":"] && YCYInvoke(mgr, s, nil)) return YES;
    }

    NSArray *oneArg = @[
        @"open:", @"unlock:", @"openLock:", @"bleOpen:", @"doOpen:",
        @"sendOpen:", @"bleUnlock:", @"_init_ble:", @"initBle:",
        @"ble_do:", @"bleDo:", @"sendCommand:", @"sendCmd:",
        @"writeCommand:", @"openWithType:", @"openType:",
        @"setAction:", @"doAction:", @"execute:", @"unlockWithMac:",
        @"openLockWithPeripheral:"
    ];
    for (NSString *s in gDCBLEOpenSels) {
        if ([s hasSuffix:@":"] && ![oneArg containsObject:s]) {
            oneArg = [oneArg arrayByAddingObject:s];
        }
    }
    NSArray *args = @[
        @"open",
        @{@"type": @"open", @"action": @"open", @"cmd": @"open"},
        @{@"command": @"open"},
        lastLockUUID.UUIDString ?: @"",
        lastAppPeripheral ?: [NSNull null]
    ];
    for (NSString *s in oneArg) {
        for (id a in args) {
            id arg = (a == [NSNull null]) ? nil : a;
            if (YCYInvoke(mgr, s, arg)) return YES;
        }
    }
    YCYLog(@"DCBLEManager 没有匹配到开锁方法，请把上面 dump 列表发回来");
    return NO;
}

static void YCYDumpDCBLENow(NSString *reason) {
    YCYLog(@"强制 dump DCBLE reason=%@", reason);
    id mgr = YCYFindDCBLE();
    Class cls = mgr ? [mgr class] : NSClassFromString(@"DCBLEManager");
    if (cls) {
        YCYDumpClassDetailed(cls);
        if (mgr) YCYHookDCBLENotify([mgr class]);
    } else {
        YCYLog(@"进程里没有 DCBLEManager 类");
    }
    if (mgr && [mgr respondsToSelector:@selector(dcDelegate)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id del = [mgr performSelector:@selector(dcDelegate)];
        #pragma clang diagnostic pop
        YCYLog(@"dcDelegate class=%@", del ? NSStringFromClass([del class]) : @"nil");
        if (del) YCYDumpClassDetailed([del class]);
    }
    if (mgr) {
        Ivar iv = class_getInstanceVariable([mgr class], "_centralManager");
        if (iv) {
            id cm = object_getIvar(mgr, iv);
            YCYLog(@"ivar _centralManager=%@ state=%ld",
                   cm ? NSStringFromClass([cm class]) : @"nil",
                   [cm isKindOfClass:[CBCentralManager class]] ? (long)[(CBCentralManager *)cm state] : -1);
            if ([cm isKindOfClass:[CBCentralManager class]] && !appCentral) {
                appCentral = (CBCentralManager *)cm;
            }
        }
    }
    YCYLog(@"候选开锁 %lu: %@", (unsigned long)gDCBLEOpenSels.count,
           gDCBLEOpenSels.count ? [gDCBLEOpenSels componentsJoinedByString:@", "] : @"(空)");
    YCYLog(@"候选连接 %lu: %@", (unsigned long)gDCBLEConnectSels.count,
           gDCBLEConnectSels.count ? [gDCBLEConnectSels componentsJoinedByString:@", "] : @"(空)");
}

static CBCentralManager *YCYAnyCentral(void) {
    if (appCentral) return appCentral;
    id mgr = YCYFindDCBLE();
    if (!mgr) return nil;
    Ivar iv = class_getInstanceVariable([mgr class], "_centralManager");
    if (!iv) return nil;
    id cm = object_getIvar(mgr, iv);
    if ([cm isKindOfClass:[CBCentralManager class]]) {
        appCentral = (CBCentralManager *)cm;
        return appCentral;
    }
    return nil;
}

static CBPeripheral *YCYRetrieveLockPeripheral(void) {
    CBPeripheral *p = lastAppPeripheral;
    if (p && p.state == CBPeripheralStateConnected) return p;

    CBCentralManager *c = YCYAnyCentral();
    if (!c) {
        YCYLog(@"retrieve 失败：没有 CBCentralManager");
        return p;
    }
    NSMutableArray *ids = [NSMutableArray array];
    if (lastLockUUID) [ids addObject:lastLockUUID];
    if (ids.count) {
        NSArray *known = [c retrievePeripheralsWithIdentifiers:ids];
        YCYLog(@"retrievePeripherals count=%lu uuid=%@",
               (unsigned long)known.count, lastLockUUID.UUIDString);
        if (known.firstObject) {
            p = known.firstObject;
            YCYRememberPeripheral(p);
            lastAppPeripheral = p;
            return p;
        }
    }
    NSArray *svcs = @[
        [CBUUID UUIDWithString:kYCYSvc9000],
        [CBUUID UUIDWithString:kYCYSvcAE00]
    ];
    NSArray *already = [c retrieveConnectedPeripheralsWithServices:svcs];
    YCYLog(@"retrieveConnected count=%lu", (unsigned long)already.count);
    for (CBPeripheral *x in already) {
        if (YCYLooksLikeLockName(x.name) || (lastLockUUID && [x.identifier isEqual:lastLockUUID])) {
            YCYRememberPeripheral(x);
            lastAppPeripheral = x;
            return x;
        }
    }
    return already.firstObject;
}

static BOOL YCYInvokeDCBLEConnect6(CBPeripheral *p) {
    id mgr = YCYFindDCBLE();
    if (!mgr || !p) return NO;
    SEL sel = NSSelectorFromString(@"connectPeripheral:connectOptions:stopScanAfterConnected:servicesOptions:characteristicsOptions:completeBlock:");
    if (![mgr respondsToSelector:sel]) {
        YCYLog(@"DCBLE 没有 6 参 connectPeripheral");
        return NO;
    }
    NSMethodSignature *sig = [mgr methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments < 8) {
        YCYLog(@"6 参 connect signature 不对 nargs=%lu", (unsigned long)sig.numberOfArguments);
        return NO;
    }
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    inv.target = mgr;

    CBPeripheral *peri = p;
    [inv setArgument:&peri atIndex:2];

    NSDictionary *opts = @{};
    [inv setArgument:&opts atIndex:3];

    const char *tStop = [sig getArgumentTypeAtIndex:4];
    if (tStop && (tStop[0] == 'B' || tStop[0] == 'c' || tStop[0] == 'C')) {
        unsigned char stop = 1;
        [inv setArgument:&stop atIndex:4];
    } else {
        BOOL stop = YES;
        [inv setArgument:&stop atIndex:4];
    }

    NSArray *svcs = @[
        [CBUUID UUIDWithString:kYCYSvc9000],
        [CBUUID UUIDWithString:kYCYSvcAE00]
    ];
    [inv setArgument:&svcs atIndex:5];

    NSArray *chars = @[
        [CBUUID UUIDWithString:kYCYChar9001],
        [CBUUID UUIDWithString:kYCYChar9002],
        [CBUUID UUIDWithString:kYCYCharAE01],
        [CBUUID UUIDWithString:kYCYCharAE02]
    ];
    [inv setArgument:&chars atIndex:6];

    void (^cb)(CBPeripheral *, NSError *) = ^(CBPeripheral *peri2, NSError *err) {
        YCYLog(@"DCBLE 6参 complete peri=%@ err=%@",
               YCYPeripheralName(peri2), err);
        if (peri2) {
            lastAppPeripheral = peri2;
            YCYRememberPeripheral(peri2);
        }
    };
    [inv setArgument:&cb atIndex:7];
    [inv retainArguments];

    YCYLog(@"invoke 6参 connectPeripheral name=%@ uuid=%@",
           YCYPeripheralName(p), p.identifier.UUIDString);
    @try {
        [inv invoke];
        return YES;
    } @catch (NSException *ex) {
        YCYLog(@"6参 connect 异常: %@", ex.reason);
        return NO;
    }
}

static BOOL YCYTryNativeConnect(void) {
    CBPeripheral *p = YCYRetrieveLockPeripheral();
    BOOL started = NO;
    if (p) {
        lastAppPeripheral = p;
        YCYRememberPeripheral(p);
        if (p.state == CBPeripheralStateConnected) {
            YCYLog(@"外设已经是 Connected %@", YCYPeripheralName(p));
            return YES;
        }
        if (YCYInvokeDCBLEConnect6(p)) started = YES;
        CBCentralManager *c = YCYAnyCentral();
        if (c && c.state == CBManagerStatePoweredOn) {
            YCYLog(@"appCentral connectPeripheral %@", YCYPeripheralName(p));
            [c connectPeripheral:p options:nil];
            started = YES;
        }
        return started;
    }
    YCYLog(@"没有已记住的 YS04，改为扫描（不会把 scan 当成已连接）");
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
        lastAppPeripheral = p;
        if (p.state == CBPeripheralStateConnected) {
            YCYLog(@"appCentral 外设已连接 %@ state=%ld", YCYPeripheralName(p), (long)p.state);
            return YES;
        }
        YCYLog(@"appCentral 正在连接 %@ state=%ld（不抢 DCBLEManager）",
               YCYPeripheralName(p), (long)p.state);
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

static void YCYNoteNewSession(NSString *reason) {
    if (gLastSessionNote && [gLastSessionNote timeIntervalSinceNow] > -4.0) {
        gHandshakeWritesLeft = kYCYHandshakeWrites;
        gHandshakeUntil = [NSDate dateWithTimeIntervalSinceNow:kYCYHandshakeSeconds];
        YCYLog(@"会话合并 reason=%@ gen=%lu（刷新握手窗口，不加倍计数）",
               reason, (unsigned long)gSessionGen);
        return;
    }
    gLastSessionNote = [NSDate date];
    gSessionGen += 1;
    gNeedsRediscover = YES;
    gHandshakeWritesLeft = kYCYHandshakeWrites;
    gHandshakeUntil = [NSDate dateWithTimeIntervalSinceNow:kYCYHandshakeSeconds];
    gHeartbeatSeen = NO;
    gSawDiscoverChars = NO;
    gDidDiscoverServices = NO;
    gDiscoveredCharacteristicCount = 0;
    gSessionNotifySeen = NO;
    gSessionHandshakeWrite = NO;
    gDidPostConnect = NO;
    [recordLock lock];
    [liveSession removeAllObjects];
    [payloadCounts removeAllObjects];
    [recordLock unlock];
    YCYLog(@"新会话 gen=%lu reason=%@ 握手窗口 %.0fs / 前 %ld 包跳过",
           (unsigned long)gSessionGen, reason, kYCYHandshakeSeconds, (long)kYCYHandshakeWrites);
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

static BOOL YCYHasRequiredBLELayout(CBPeripheral *peripheral) {
    if (!peripheral || peripheral.state != CBPeripheralStateConnected) return NO;
    BOOL has9001 = NO, has9002 = NO;
    for (CBService *service in peripheral.services) {
        for (CBCharacteristic *c in service.characteristics) {
            has9001 |= YCYUUIDMatch(c.UUID.UUIDString, kYCYChar9001);
            has9002 |= YCYUUIDMatch(c.UUID.UUIDString, kYCYChar9002);
        }
    }
    return has9001 && has9002;
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
        if (dt <= kYCYUnlockCluster) [tail addObject:w];
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
    if (gHelloPayload.length) {
        [ud setObject:[gHelloPayload base64EncodedStringWithOptions:0] forKey:kYCYHelloKey];
        if (gHelloCharUUID.length) [ud setObject:gHelloCharUUID forKey:kYCYHelloCharKey];
    }
    [ud synchronize];
}

static void YCYLoadRecords(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *arr = [ud arrayForKey:kYCYRecordsKey];
    if (arr.count == 0) arr = [ud arrayForKey:kYCYRecordsKeyV3];
    if (arr.count == 0) arr = [ud arrayForKey:kYCYRecordsKeyV2];
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
    NSString *helloB64 = [ud stringForKey:kYCYHelloKey];
    if (helloB64.length) {
        gHelloPayload = [[NSData alloc] initWithBase64EncodedString:helloB64 options:0];
        gHelloCharUUID = [ud stringForKey:kYCYHelloCharKey];
        NSLog(@"[YCYUnlock] 已加载握手首包 %lu 字节", (unsigned long)gHelloPayload.length);
    }
}

#pragma mark - 记录 / 重放

static NSArray<YCYRecordedWrite *> *YCYCanonicalCopy(void) {
    [recordLock lock];
    NSArray *all = [canonicalWrites copy];
    [recordLock unlock];
    return all;
}

static BOOL YCYCanFreezeNow(void) {
    if (gCaptureArmed) return YES;
    if (gHeartbeatSeen) return YES;
    return NO;
}

static void YCYFreezeCanonicalFromSession(void) {
    [recordLock lock];
    if (!YCYCanFreezeNow()) {
        YCYLog(@"冻结推迟：还没心跳，也没点「开始捕获」 live=%lu",
               (unsigned long)liveSession.count);
        [recordLock unlock];
        return;
    }
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
        gCaptureArmed = NO;
        didFreeze = YES;
        gFrozenSessionGen = gSessionGen;
        YCYLog(@"★ 冻结唯一开锁包 %lu 条（心跳门控/手动捕获，关锁不再覆盖）",
               (unsigned long)canonicalWrites.count);
        for (YCYRecordedWrite *w in canonicalWrites) {
            YCYLog(@"  冻结 HEX=%@", YCYHexString(w.value));
        }
    } else {
        YCYLog(@"冻结跳过：当前窗口没有唯一密文 live=%lu heartbeat=%d armed=%d",
               (unsigned long)liveSession.count, gHeartbeatSeen, gCaptureArmed);
    }
    [recordLock unlock];
    if (didFreeze) {
        YCYPersistRecords();
        YCYShowToast([NSString stringWithFormat:@"已冻结 %lu 条唯一开锁包",
                      (unsigned long)unique.count]);
    }
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kYCYFreezeIdle * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), block);
}

static void YCYArmCapture(void) {
    if (gFreezeBlock) {
        dispatch_block_cancel(gFreezeBlock);
        gFreezeBlock = nil;
    }
    [recordLock lock];
    [liveSession removeAllObjects];
    gCanonicalFrozen = NO;
    gCaptureArmed = YES;
    [recordLock unlock];
    YCYLog(@"开始捕获：已清空本段 liveSession，等控方开锁");
    YCYShowToast(@"捕获已开始\n现在让控方开锁一次\n锁动了再看冻结提示");
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
    BOOL isFrozenHex = NO;
    if (gCanonicalFrozen) {
        [recordLock lock];
        YCYRecordedWrite *fw = canonicalWrites.firstObject;
        NSData *fv = [fw.value copy];
        [recordLock unlock];
        if (fv && [fv isEqualToData:data]) isFrozenHex = YES;
    }
    if (!isFrozenHex && data.length == 16) {
        gSessionHandshakeWrite = YES;
    }

    [recordLock lock];
    NSInteger seen = [payloadCounts[hex] integerValue] + 1;
    payloadCounts[hex] = @(seen);
    if (seen >= 2) gHeartbeatSeen = YES;
    [recordLock unlock];

    if (gCanonicalFrozen && !gCaptureArmed) {
        YCYLog(@"已冻结，忽略写包 unique=%@ count=%ld HEX=%@",
               seen == 1 ? @"YES" : @"NO", (long)seen, hex);
        lastLockUUID = peripheral.identifier;
        lastLockName = YCYPeripheralName(peripheral);
        return;
    }

    BOOL handshakeSkip = NO;
    if (!gCaptureArmed) {
        if (gHandshakeWritesLeft > 0) {
            gHandshakeWritesLeft--;
            handshakeSkip = YES;
        }
        if (gHandshakeUntil && [gHandshakeUntil timeIntervalSinceNow] > 0) {
            handshakeSkip = YES;
        }
    }
    if (handshakeSkip) {
        if (!gHelloPayload && data.length == 16) {
            gHelloPayload = [data copy];
            gHelloCharUUID = charUUID;
            YCYLog(@"记住握手首包 char=%@ HEX=%@", charUUID, hex);
            YCYPersistRecords();
        }
        YCYLog(@"握手/建会话，跳过记录 left=%ld hb=%d HEX=%@",
               (long)gHandshakeWritesLeft, gHeartbeatSeen, hex);
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

    YCYLog(@"★ 记录 %@ count=%ld live=%lu hb=%d armed=%d char=%@ HEX=%@",
           item.heartbeatLike ? @"心跳/重复" : @"唯一候选",
           (long)seen,
           (unsigned long)liveCount,
           gHeartbeatSeen,
           gCaptureArmed,
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

static CBPeripheral *YCYReadyLock(void) {
    CBPeripheral *p = lastAppPeripheral;
    if (p && p.state == CBPeripheralStateConnected) return p;
    NSArray *connected = YCYConnectedPeripherals();
    p = YCYPickPeripheral(connected, lastLockUUID);
    if (p && p.state == CBPeripheralStateConnected) {
        lastAppPeripheral = p;
        return p;
    }
    if (lastLockUUID && appCentral) {
        NSArray *known = [appCentral retrievePeripheralsWithIdentifiers:@[lastLockUUID]];
        p = known.firstObject;
        if (p) {
            YCYRememberPeripheral(p);
            if (p.state == CBPeripheralStateConnected) {
                lastAppPeripheral = p;
                return p;
            }
        }
    }
    return nil;
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

    YCYLog(@"开始重放唯一包 packets=%lu / recorded=%lu needsRediscover=%d session=%lu/%lu",
           (unsigned long)packets.count, (unsigned long)burst.count, gNeedsRediscover,
           (unsigned long)gFrozenSessionGen, (unsigned long)gSessionGen);
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

static NSString * const kYCYJSTrapScript =
    @"(function(g){"
    "if(g.__ycy_trap)return 'already';"
    "g.__ycy_trap=1;"
    "function trap(name){"
    "try{"
    "var store='__ycy_'+name;"
    "Object.defineProperty(Object.prototype,name,{"
    "configurable:true,enumerable:false,"
    "set:function(v){"
    "try{g[store]=v;}catch(e){}"
    "try{Object.defineProperty(this,name,{value:v,writable:true,configurable:true,enumerable:true});}"
    "catch(e){}"
    "}"
    "});"
    "}catch(e){return String(e);}"
    "}"
    "trap('_ble_do');trap('_init_ble');trap('_ble_send');trap('_tp_uni_jm');"
    "return 'trapped';"
    "})(this)";

static NSString * const kYCYJSOpenScript =
    @"(function(g){try{"
    "var fn=g.__ycy__ble_do||g._ble_do||g.__ycy_ble_do;"
    "if(typeof fn==='function'){fn('open');return 'opened:trap_ble_do';}"
    "if(typeof _ble_do==='function'){_ble_do('open');return 'opened:_ble_do';}"
    "return 'miss';"
    "}catch(e){return 'err:'+String(e);}})(this)";

static void YCYLogScriptNeedle(NSString *script, NSString *needle) {
    if (script.length == 0 || needle.length == 0) return;
    NSRange r = [script rangeOfString:needle];
    if (r.location == NSNotFound) return;
    NSUInteger from = r.location > 90 ? r.location - 90 : 0;
    NSUInteger len = MIN((NSUInteger)200, script.length - from);
    NSString *snip = [script substringWithRange:NSMakeRange(from, len)];
    snip = [[snip componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]
            componentsJoinedByString:@" "];
    if (snip.length > 180) snip = [snip substringToIndex:180];
    YCYLog(@"JS 源码命中 %@ …%@…", needle, snip);
}

static void YCYInstallJSTrap(JSContext *ctx) {
    if (!ctx) return;
    YCYInitState();
    NSNumber *key = @((uintptr_t)(__bridge void *)ctx);
    @synchronized (gJSContextTraps) {
        if ([gJSContextTraps containsObject:key]) return;
        [gJSContextTraps addObject:key];
    }
    @synchronized (jsContexts) {
        [jsContexts addObject:ctx];
    }
    BOOL old = gInJSProbe;
    gInJSProbe = YES;
    @try {
        JSValue *v = [ctx evaluateScript:kYCYJSTrapScript];
        YCYLog(@"JS trap %@", v.isString ? v.toString : @"?");
    } @catch (NSException *ex) {
        YCYLog(@"JS trap 异常: %@", ex.reason);
    }
    gInJSProbe = old;
}

static void YCYRememberJSContext(JSContext *ctx) {
    if (!ctx || gInJSProbe) return;
    YCYInstallJSTrap(ctx);
    static BOOL probed = NO;
    if (probed) return;
    probed = YES;
    gInJSProbe = YES;
    @try {
        JSValue *v = [ctx evaluateScript:
            @"(function(){var a=[];function w(o,p,d){if(!o||d>3)return;try{var ks=Object.keys(o);for(var i=0;i<ks.length&&i<60;i++){var k=ks[i];if(/ble|open|lock|unlock|jm|ys0|dcble/i.test(k))a.push(p+k);var v=o[k];if(v&&typeof v==='object')w(v,p+k+'.',d+1);}}catch(e){}}"
            "try{if(typeof _ble_do==='function')a.push('_ble_do');"
            "if(typeof _init_ble==='function')a.push('_init_ble');"
            "if(typeof __ycy__ble_do==='function')a.push('trap._ble_do');"
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
    gInJSProbe = YES;
    BOOL opened = NO;
    for (JSContext *ctx in ctxs) {
        @try {
            JSValue *v = [ctx evaluateScript:kYCYJSOpenScript];
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

static BOOL YCYEvalJSAll(NSString *script, NSString *tag, NSString *successPrefix) {
    NSArray *ctxs;
    @synchronized (jsContexts) {
        ctxs = [[jsContexts allObjects] copy];
    }
    if (ctxs.count == 0) {
        YCYLog(@"无 JSContext，跳过 %@", tag);
        return NO;
    }
    gInJSProbe = YES;
    BOOL ok = NO;
    for (JSContext *ctx in ctxs) {
        @try {
            JSValue *v = [ctx evaluateScript:script];
            NSString *s = v.isString ? v.toString : @"nil";
            YCYLog(@"%@ result=%@", tag, s);
            if (successPrefix.length && [s hasPrefix:successPrefix]) ok = YES;
            if ([s hasPrefix:@"uni."] || [s hasPrefix:@"plus."]) ok = YES;
        } @catch (NSException *ex) {
            YCYLog(@"%@ 异常: %@", tag, ex.reason);
        }
    }
    gInJSProbe = NO;
    return ok;
}

static BOOL YCYTryJSConnect(void) {
    NSString *uuid = lastLockUUID.UUIDString ?: @"";
    if (uuid.length == 0) {
        YCYLog(@"JS connect 没有 lastLockUUID");
        return NO;
    }
    NSString *script = [NSString stringWithFormat:
        @"(function(){try{"
        "var id='%@';"
        "if(typeof uni!=='undefined'&&typeof uni.createBLEConnection==='function'){"
        "uni.createBLEConnection({deviceId:id,timeout:15000});"
        "return 'uni.createBLEConnection';}"
        "if(typeof plus!=='undefined'&&plus.bluetooth&&typeof plus.bluetooth.createBLEConnection==='function'){"
        "plus.bluetooth.createBLEConnection({deviceId:id});"
        "return 'plus.bluetooth.createBLEConnection';}"
        "var u=(typeof uni!=='undefined')?Object.keys(uni).filter(function(k){return /ble|lock|open/i.test(k);}).slice(0,20).join(','):'no-uni';"
        "var p=(typeof plus!=='undefined'&&plus.bluetooth)?Object.keys(plus.bluetooth).slice(0,20).join(','):'no-plus.bt';"
        "return 'miss uniKeys='+u+' plusBt='+p;"
        "}catch(e){return 'err:'+String(e);}})()", uuid];
    return YCYEvalJSAll(script, @"JS connect", @"uni.create");
}

static __attribute__((unused)) id YCYFindLibBT(void) {
    id mgr = YCYFindDCBLE();
    if (mgr && [mgr respondsToSelector:@selector(dcDelegate)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id del = [mgr performSelector:@selector(dcDelegate)];
        #pragma clang diagnostic pop
        if (del) return del;
    }
    return nil;
}

static __attribute__((unused)) id YCYMakePGCommand(NSDictionary *opts) {
    Class C = NSClassFromString(@"PGMethod");
    if (!C) return @[opts ?: @{}];
    id cmd = [[C alloc] init];
    @try { [cmd setValue:@[opts ?: @{}] forKey:@"arguments"]; } @catch (__unused NSException *e) {}
    @try { [cmd setValue:@"YCYUnlock" forKey:@"callBackID"]; } @catch (__unused NSException *e) {}
    @try { [cmd setValue:@"Bluetooth" forKey:@"featureName"]; } @catch (__unused NSException *e) {}
    return cmd;
}

static __attribute__((unused)) BOOL YCYInvokeLibBT(NSString *selName, NSDictionary *opts) {
    id plugin = YCYFindLibBT();
    if (!plugin) {
        YCYLog(@"没有 libBlueTooth，跳过 %@", selName);
        return NO;
    }
    SEL sel = NSSelectorFromString(selName);
    if (![plugin respondsToSelector:sel]) {
        YCYLog(@"libBlueTooth 无 %@", selName);
        return NO;
    }
    id arg = YCYMakePGCommand(opts);
    YCYLog(@"invoke [libBlueTooth %@] %@", selName, opts[@"deviceId"] ?: @"");
    @try {
        NSMethodSignature *sig = [plugin methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments < 3) return NO;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.target = plugin;
        inv.selector = sel;
        [inv setArgument:&arg atIndex:2];
        [inv retainArguments];
        [inv invoke];
        return YES;
    } @catch (NSException *ex) {
        YCYLog(@"libBlueTooth %@ 异常: %@", selName, ex.reason);
        return NO;
    }
}

static BOOL YCYTryJSHandshake(void) {
    NSString *uuid = lastLockUUID.UUIDString ?: @"";
    NSString *script = [NSString stringWithFormat:
        @"(function(g){try{"
        "var id='%@';"
        "var svc='00009000-0000-1000-8000-57616C6B697A';"
        "var ntf='00009002-0000-1000-8000-57616C6B697A';"
        "if(typeof plus!=='undefined'&&plus.bluetooth&&plus.bluetooth.notifyBLECharacteristicValueChange){"
        "plus.bluetooth.notifyBLECharacteristicValueChange({deviceId:id,serviceId:svc,characteristicId:ntf,state:true});"
        "}"
        "if(typeof uni!=='undefined'&&uni.notifyBLECharacteristicValueChange){"
        "uni.notifyBLECharacteristicValueChange({deviceId:id,serviceId:svc,characteristicId:ntf,state:true});"
        "}"
        "var fn=g.__ycy__init_ble||g._init_ble;"
        "if(typeof fn==='function'){fn('open');return 'handshake:trap_init_ble';}"
        "if(typeof _init_ble==='function'){_init_ble('open');return 'handshake:_init_ble';}"
        "return 'handshake:notify-only';"
        "}catch(e){return 'err:'+String(e);}})(this)", uuid];
    return YCYEvalJSAll(script, @"JS handshake", @"handshake:");
}

static BOOL YCYReplayHello(CBPeripheral *p) {
    if (!gHelloPayload.length || !p) {
        YCYLog(@"无握手首包，跳过重放 hello");
        return NO;
    }
    CBCharacteristic *c = YCYFindCharacteristic(p, kYCYSvc9000,
        gHelloCharUUID.length ? gHelloCharUUID : kYCYChar9001);
    if (!c) {
        NSArray *cs = YCYWriteCharacteristics(p);
        c = cs.firstObject;
    }
    if (!c) {
        YCYLog(@"握手首包无法写：特征还没发现");
        return NO;
    }
    YCYLog(@"重放握手首包 char=%@ HEX=%@", c.UUID.UUIDString, YCYHexString(gHelloPayload));
    gIgnoreHookWrite = YES;
    [p writeValue:gHelloPayload forCharacteristic:c type:CBCharacteristicWriteWithoutResponse];
    gIgnoreHookWrite = NO;
    return YES;
}

static void YCYStartPostConnectHandshake(CBPeripheral *p) {
    if (gDidPostConnect) return;
    if (!YCYHasRequiredBLELayout(p)) {
        YCYLog(@"握手延后：服务/特征尚未完整 layout=%@", p.services);
        return;
    }
    gDidPostConnect = YES;
    YCYLog(@"连上后开始握手 notify=%d hello=%lu chars=%lu",
           gSessionNotifySeen, (unsigned long)gHelloPayload.length,
           (unsigned long)gDiscoveredCharacteristicCount);
    // 不再反射调用 libBlueTooth。日志中的 index 1 beyond bounds 说明
    // PGPlugin 仍处于 JS 设备数组未建立的阶段；CoreBluetooth 已经足够完成发现/订阅。
    YCYEnableNotifies(p);
    YCYTryJSHandshake();
    if (p && p.services.count > 0) YCYReplayHello(p);
}

#pragma mark - 自建 BLE 连接（仅发现/保活，禁止写旧密文）

@interface YCYBleEngine : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@property (nonatomic, strong) CBCentralManager *central;
@property (nonatomic, strong) CBPeripheral *target;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) BOOL done;
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
    YCYLog(@"独立连接流程失败: %@", msg);
    self.busy = NO;
    self.done = YES;
    YCYFinishUnlockFlight();
    [self.central stopScan];
    YCYShowToast(msg);
}

- (BOOL)hasWriteChars:(CBPeripheral *)p {
    return YCYWriteCharacteristics(p).count > 0;
}

- (void)discoverOn:(CBPeripheral *)peripheral {
    self.target = peripheral;
    peripheral.delegate = self;
    YCYLog(@"独立引擎发现服务 %@", YCYPeripheralName(peripheral));
    NSArray *svcs = @[
        [CBUUID UUIDWithString:kYCYSvc9000],
        [CBUUID UUIDWithString:kYCYSvcAE00]
    ];
    [peripheral discoverServices:svcs];
}

- (void)connectPeripheral:(CBPeripheral *)peripheral {
    if (!peripheral) return;
    YCYLog(@"独立引擎连接 %@ %@", YCYPeripheralName(peripheral), peripheral.identifier.UUIDString);
    self.target = peripheral;
    [self.central stopScan];
    [self.central connectPeripheral:peripheral options:nil];
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (central.state != CBManagerStatePoweredOn && self.busy) {
        [self failWith:@"系统蓝牙未打开"];
    }
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    (void)central;
    YCYLog(@"独立引擎已连接（不会写旧密文） %@", YCYPeripheralName(peripheral));
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
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (error) YCYLog(@"发现服务失败 %@", error);
    gDidDiscoverServices = (error == nil && peripheral.services.count > 0);
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
    if (error) YCYLog(@"发现特征失败 service=%@ error=%@", service.UUID.UUIDString, error);
    if (!error) {
        gDiscoveredCharacteristicCount += service.characteristics.count;
        gSawDiscoverChars = YES;
    }
    self.pendingDiscover--;
    if (self.pendingDiscover <= 0 && !self.done) {
        if ([self hasWriteChars:peripheral]) {
            YCYEnableNotifies(peripheral);
            self.done = YES;
            self.busy = NO;
            YCYLog(@"独立引擎只开通知，不写旧密文。请走 App 握手后的原生/JS 开锁");
            YCYShowToast(@"独立连接已建立\n不会重放旧密文\n请再短按一次走原生开锁");
            YCYFinishUnlockFlight();
        } else {
            [self failWith:@"已连接但没有可写特征"];
        }
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

static BOOL YCYSameSession(BOOL appConnected) {
    if (!appConnected) return NO;
    if (gNeedsRediscover) return NO;
    if (gFrozenSessionGen == 0) return NO;
    return gFrozenSessionGen == gSessionGen;
}

static void YCYDoReplay(NSArray *burst, CBPeripheral *ready) {
    NSInteger n = YCYReplayBurstOnPeripheral(burst, ready);
    if (n <= 0) {
        YCYShowToast(@"没有唯一开锁包\n请先「开始捕获」再让控方开锁一次");
    } else {
        YCYShowToast([NSString stringWithFormat:@"正在重放 %ld 条唯一指令（同会话）", (long)n]);
    }
}

static void YCYPollUnlockAfterReconnect(int attempts, BOOL tryJS) {
    CBPeripheral *ready = YCYReadyLock();
    BOOL isReady = (ready.state == CBPeripheralStateConnected);
    NSUInteger svcCount = ready.services.count;
    BOOL charsReady = YCYHasRequiredBLELayout(ready);
    BOOL handshakeOk = gSessionNotifySeen || gSessionHandshakeWrite;

    YCYLog(@"重连轮询 #%d ready=%@ state=%ld chars=%d svcs=%lu discovered=%lu sawChars=%d didSvcs=%d notify=%d hsWrite=%d hello=%lu lastApp=%@",
           attempts,
           YCYPeripheralName(ready),
           ready ? (long)ready.state : -1,
           charsReady,
           (unsigned long)svcCount,
           (unsigned long)gDiscoveredCharacteristicCount,
           gSawDiscoverChars,
           gDidDiscoverServices,
           gSessionNotifySeen,
           gSessionHandshakeWrite,
           (unsigned long)gHelloPayload.length,
           YCYPeripheralName(lastAppPeripheral));

    if (isReady && charsReady) {
        YCYStartPostConnectHandshake(ready);
        YCYEnableNotifies(ready);
        if (handshakeOk && tryJS && !gDidJSOpenThisFlight) {
            gDidJSOpenThisFlight = YES;
            if (YCYTryJSOpen()) {
                YCYShowToast(@"握手完成，已调用 _ble_do");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ YCYFinishUnlockFlight(); });
                return;
            }
        }
        if (!handshakeOk && attempts == 3 && ready) {
            YCYReplayHello(ready);
        }
    }

    if (attempts < 12) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YCYPollUnlockAfterReconnect(attempts + 1, tryJS);
        });
        return;
    }

    YCYLog(@"重连超时 notify=%d hsWrite=%d，拒绝用旧密文", gSessionNotifySeen, gSessionHandshakeWrite);
    YCYShowToast(@"已连上但没等到新握手\n请复制日志");
    YCYFinishUnlockFlight();
}

static void YCYTryUnlockWithBurst(NSArray *burst, BOOL tryJS) {
    YCYInitState();
    if (gUnlockInFlight) {
        YCYShowToast(@"正在开锁，请稍候");
        return;
    }

    CBPeripheral *ready = YCYReadyLock();
    BOOL appConnected = ready && ready.state == CBPeripheralStateConnected;
    BOOL sameSession = YCYSameSession(appConnected);

    YCYLog(@"尝试开锁 connected=%d sameSession=%d frozen=%d js=%d native=%@ session=%lu/%lu hb=%d armed=%d lastApp=%@ state=%ld",
           appConnected,
           sameSession,
           gCanonicalFrozen,
           tryJS,
           gDCBLE ? NSStringFromClass([gDCBLE class]) : @"nil",
           (unsigned long)gFrozenSessionGen,
           (unsigned long)gSessionGen,
           gHeartbeatSeen,
           gCaptureArmed,
           YCYPeripheralName(lastAppPeripheral),
           ready ? (long)ready.state : -1);

    gUnlockInFlight = YES;
    gDidJSOpenThisFlight = NO;
    gDidPostConnect = NO;
    YCYSetButtonBusy(YES);

    if (appConnected && sameSession && tryJS && YCYTryJSOpen()) {
        YCYShowToast(@"同会话，已调用 _ble_do");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YCYFinishUnlockFlight();
        });
        return;
    }

    if (appConnected && sameSession) {
        if (!gCanonicalFrozen) YCYFreezeCanonicalFromSession();
        NSArray *effective = burst;
        if (effective.count == 0) {
            effective = YCYUniqueUnlockPackets(YCYCanonicalCopy());
        } else {
            NSArray *filtered = YCYUniqueUnlockPackets(effective);
            if (filtered.count) effective = filtered;
        }
        if (effective.count == 0) {
            YCYFinishUnlockFlight();
            YCYShowToast(@"同会话没有可重放的包\n长按 → 开始捕获");
            return;
        }
        YCYDoReplay(effective, ready);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YCYFinishUnlockFlight();
        });
        return;
    }

    if (appConnected && !sameSession) {
        YCYLog(@"已连接但是新会话，先握手再 _ble_do");
        YCYStartPostConnectHandshake(ready);
        YCYShowToast(@"已连上，正在握手…");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YCYPollUnlockAfterReconnect(1, tryJS);
        });
        return;
    }

    if (!appConnected) {
        YCYLog(@"未连接：6参 DCBLE connect + appCentral.connect + JS createBLEConnection");
        BOOL started = YCYTryNativeConnect();
        if (!started) started = YCYConnectViaAppCentral();
        BOOL js = YCYTryJSConnect();
        if (started || js) {
            YCYShowToast(@"正在连接 YS04…\n连上后先握手再开锁");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                YCYPollUnlockAfterReconnect(1, tryJS);
            });
            return;
        }
        YCYFinishUnlockFlight();
        YCYShowToast(@"无法重连\n请先打开 App 蓝牙页再试");
        return;
    }
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
            [text appendString:@"暂无已记录的开锁指令\n请：锁已连上并稳定 → 长按「开始捕获」→ 让控方开锁一次\n插件只保存心跳之后的唯一密文"];
        } else {
            [text appendFormat:@"状态：%@\n唯一包：%lu  原始：%lu\n会话：%lu / 当前 %lu\n\n",
             gCanonicalFrozen ? @"已冻结（只重放唯一包）" : (gCaptureArmed ? @"捕获中" : @"采集中"),
             (unsigned long)unique.count,
             (unsigned long)all.count,
             (unsigned long)gFrozenSessionGen,
             (unsigned long)gSessionGen];
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
    gCaptureArmed = NO;
    gHeartbeatSeen = NO;
    gFrozenSessionGen = 0;
    [recordLock unlock];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud removeObjectForKey:kYCYRecordsKey];
    [ud removeObjectForKey:kYCYRecordsKeyV3];
    [ud removeObjectForKey:kYCYRecordsKeyV2];
    [ud setBool:NO forKey:@"YCYUnlock.frozen"];
    [ud synchronize];
    YCYLog(@"Records cleared — 请开始捕获后再官方开锁");
    YCYShowToast(@"已清空。下一步：长按 → 开始捕获");
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
        @"短按：开锁（原生优先，同会话才重放）\n长按：本菜单\nv%@  监控：%@\n唯一包：%lu  原始：%lu%@\n心跳：%@  捕获：%@\n已连接：%lu",
        kYCYVersion,
        monitorEnabled ? @"开" : @"关",
        (unsigned long)unique.count,
        (unsigned long)canon.count,
        gCanonicalFrozen ? @"（已冻结）" : @"",
        gHeartbeatSeen ? @"已见" : @"未见",
        gCaptureArmed ? @"进行中" : @"关",
        (unsigned long)YCYConnectedPeripherals().count];

    UIAlertController *menu =
        [UIAlertController alertControllerWithTitle:@"YCY Unlock"
                                            message:msg
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    [menu addAction:[UIAlertAction actionWithTitle:gCaptureArmed ? @"停止捕获" : @"开始捕获（推荐）"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *a) {
                                               (void)a;
                                               if (gCaptureArmed) {
                                                   gCaptureArmed = NO;
                                                   YCYShowToast(@"已停止捕获");
                                               } else {
                                                   YCYArmCapture();
                                               }
                                           }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"仅调用 DCBLEManager 开锁"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
                                               (void)a;
                                               YCYDumpDCBLENow(@"menu-native-open");
                                               if (YCYTryNativeOpen()) {
                                                   YCYShowToast(@"已调用 DCBLEManager");
                                               } else {
                                                   YCYShowToast(@"没匹配到方法，请复制日志");
                                               }
                                           }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"仅重放唯一 BLE 包（同会话）"
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
                                                   YCYShowToast(@"没找到 _ble_do，请看日志里的 JS probe / trap");
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
    [menu addAction:[UIAlertAction actionWithTitle:@"重新捕获（清空已冻结包）"
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
    if (state == CBPeripheralStateDisconnected) {
        gNeedsRediscover = YES;
        if (lastAppPeripheral == p) lastAppPeripheral = nil;
    } else if (state == CBPeripheralStateConnecting) {
        gNeedsRediscover = YES;
    } else if (state == CBPeripheralStateConnected) {
        lastAppPeripheral = p;
        YCYRememberPeripheral(p);
        YCYNoteNewSession(@"KVO-connected");
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
    if (![self.delegate isKindOfClass:[YCYBleEngine class]]) {
        appCentral = self;
        YCYNoteNewSession(@"app-connect");
    }
    if (monitorEnabled) {
        YCYLog(@"connect name=%@ UUID=%@",
               YCYPeripheralName(peripheral),
               YCYUUIDString(peripheral.identifier));
    }
    %orig;
}

- (void)cancelPeripheralConnection:(CBPeripheral *)peripheral {
    BOOL isLock = YCYLooksLikeLockName(YCYPeripheralName(peripheral));
    if (!isLock && lastLockUUID && [peripheral.identifier isEqual:lastLockUUID]) isLock = YES;
    if (gUnlockInFlight && isLock) {
        YCYLog(@"拦截 cancelConnect（开锁进行中） name=%@ UUID=%@",
               YCYPeripheralName(peripheral),
               YCYUUIDString(peripheral.identifier));
        return;
    }
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
    if (YCYUUIDMatch(service.UUID.UUIDString, kYCYSvc9000) ||
        YCYUUIDMatch(service.UUID.UUIDString, kYCYSvcAE00) ||
        [service.UUID.UUIDString.uppercaseString containsString:@"9000"] ||
        [service.UUID.UUIDString.uppercaseString containsString:@"AE00"]) {
        lastAppPeripheral = self;
        YCYRememberPeripheral(self);
        __weak CBPeripheral *weakP = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CBPeripheral *p = weakP;
            if (p.state == CBPeripheralStateConnected && YCYHasRequiredBLELayout(p)) {
                YCYEnableNotifies(p);
            }
        });
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

- (instancetype)init {
    JSContext *obj = %orig;
    YCYInstallJSTrap(obj);
    return obj;
}

- (instancetype)initWithVirtualMachine:(JSVirtualMachine *)vm {
    JSContext *obj = %orig;
    YCYInstallJSTrap(obj);
    return obj;
}

- (JSValue *)evaluateScript:(NSString *)script {
    YCYRememberJSContext(self);
    if (!gInJSProbe && script.length > 4000) {
        YCYLog(@"JS eval len=%lu", (unsigned long)script.length);
        YCYLogScriptNeedle(script, @"_ble_do");
        YCYLogScriptNeedle(script, @"_init_ble");
        YCYLogScriptNeedle(script, @"_tp_uni_jm");
    }
    return %orig;
}

- (JSValue *)evaluateScript:(NSString *)script withSourceURL:(NSURL *)sourceURL {
    YCYRememberJSContext(self);
    if (!gInJSProbe && script.length > 4000) {
        YCYLog(@"JS eval(url) len=%lu url=%@", (unsigned long)script.length, sourceURL);
        YCYLogScriptNeedle(script, @"_ble_do");
        YCYLogScriptNeedle(script, @"_init_ble");
    }
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
        YCYDumpDCBLENow(@"launch");
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
    YCYLog(@"v1.6.1 连上先握手/_init_ble，等新 NOTIFY 再 _ble_do");
    YCYLog(@"短按 = 原生/JS，同会话才重放");
    YCYLog(@"长按 = 开始捕获 / dump");
    YCYLog(@"==============================");
    YCYScheduleFloatingButton();
}

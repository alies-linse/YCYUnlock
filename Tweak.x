#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <objc/runtime.h>

#pragma mark - 全局变量

static UIWindow *floatWindow;
static UIButton *floatBtn;

// 记录到的开锁相关对象和数据
static CBPeripheral *recordedPeripheral;
static CBCharacteristic *recordedCharacteristic;
static NSData *recordedValue;
static CBCharacteristicWriteType recordedType = CBCharacteristicWriteWithoutResponse;

// YS04 已知特征 UUID
static NSString * const kService1 = @"00009000-0000-1000-8000-57616C6B697A";
static NSString * const kCharWrite1 = @"00009001-0000-1000-8000-57616C6B697A";
static NSString * const kService2 = @"AE00";
static NSString * const kCharWrite2 = @"AE01";

#pragma mark - 工具方法

static NSData *hexToData(NSString *hex) {
    NSMutableData *data = [NSMutableData data];
    hex = [[hex stringByReplacingOccurrencesOfString:@" " withString:@""] uppercaseString];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        unsigned int byte;
        [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&byte];
        uint8_t b = byte;
        [data appendBytes:&b length:1];
    }
    return data;
}

static void showToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"YCY Unlock"
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *root = UIApplication.sharedApplication.keyWindow.rootViewController;
        while (root.presentedViewController) root = root.presentedViewController;
        [root presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - 发送开锁指令

static void tryUnlock() {
    NSLog(@"[YCYUnlock] ========== 开始尝试开锁 ==========");

    // 1. 优先重放已记录的真实开锁数据
    if (recordedPeripheral && recordedCharacteristic && recordedValue) {
        NSLog(@"[YCYUnlock] 使用记录到的真实数据重放");
        NSLog(@"[YCYUnlock] Peripheral: %@", recordedPeripheral.identifier.UUIDString);
        NSLog(@"[YCYUnlock] Characteristic: %@", recordedCharacteristic.UUID.UUIDString);
        NSLog(@"[YCYUnlock] Value: %@", recordedValue);

        if (recordedPeripheral.state == CBPeripheralStateConnected) {
            [recordedPeripheral writeValue:recordedValue
                         forCharacteristic:recordedCharacteristic
                                      type:recordedType];
            showToast(@"已重放记录的开锁指令\n请观察锁盒");
            return;
        } else {
            NSLog(@"[YCYUnlock] 记录的设备当前未连接");
        }
    }

    // 2. 没有记录时，尝试向已知特征发送候选指令
    NSLog(@"[YCYUnlock] 无有效记录，尝试候选指令");

    // 候选指令（可根据后续抓包继续补充）
    NSArray *candidates = @[
        @"2001",
        @"0100",
        @"06010101",
        @"AF0FD001",
        @"AF0FC001",
        @"050106"
    ];

    // 这里只能给出提示，真正写入需要当前已连接的 peripheral
    // 完整实现需要再 Hook CBCentralManager 来保存当前连接的设备
    showToast(@"暂无记录到真实开锁数据\n请先让控方正常同意并开锁一次\n插件会自动记录指令\n之后即可一键重放");
}

#pragma mark - 悬浮窗

static void createFloatButton() {
    if (floatWindow) return;

    floatWindow = [[UIWindow alloc] initWithFrame:CGRectMake(30, 180, 64, 64)];
    floatWindow.windowLevel = UIWindowLevelAlert + 100;
    floatWindow.backgroundColor = UIColor.clearColor;
    floatWindow.hidden = NO;
    floatWindow.userInteractionEnabled = YES;

    floatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    floatBtn.frame = CGRectMake(0, 0, 64, 64);
    floatBtn.backgroundColor = [UIColor.systemRedColor colorWithAlphaComponent:0.9];
    floatBtn.layer.cornerRadius = 32;
    floatBtn.layer.masksToBounds = YES;
    [floatBtn setTitle:@"开锁" forState:UIControlStateNormal];
    floatBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [floatBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];

    [floatBtn addTarget:NSClassFromString(@"YCYUnlockHelper")
                 action:@selector(onUnlockTapped)
       forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:NSClassFromString(@"YCYUnlockHelper")
                                                                          action:@selector(onPan:)];
    [floatBtn addGestureRecognizer:pan];

    [floatWindow addSubview:floatBtn];
    [floatWindow makeKeyAndVisible];

    NSLog(@"[YCYUnlock] 悬浮窗已创建");
}

@interface YCYUnlockHelper : NSObject
@end

@implementation YCYUnlockHelper

+ (void)onUnlockTapped {
    tryUnlock();
}

+ (void)onPan:(UIPanGestureRecognizer *)pan {
    CGPoint t = [pan translationInView:floatWindow];
    floatWindow.center = CGPointMake(floatWindow.center.x + t.x, floatWindow.center.y + t.y);
    [pan setTranslation:CGPointZero inView:floatWindow];
}

@end

#pragma mark - Hook 蓝牙写入（核心）

%hook CBPeripheral

- (void)writeValue:(NSData *)data
 forCharacteristic:(CBCharacteristic *)characteristic
              type:(CBCharacteristicWriteType)type {

    // 记录所有写入，方便后续分析
    NSString *uuid = characteristic.UUID.UUIDString.uppercaseString;
    NSLog(@"[YCYUnlock] 写入特征: %@  数据: %@", uuid, data);

    // 如果是 YS04 的写入特征，或者数据看起来像开锁指令，就重点记录
    BOOL isTargetChar = [uuid containsString:@"9001"] ||
                        [uuid containsString:@"AE01"] ||
                        [uuid isEqualToString:@"00009001-0000-1000-8000-57616C6B697A"];

    if (isTargetChar || data.length >= 2) {
        recordedPeripheral = self;
        recordedCharacteristic = characteristic;
        recordedValue = [data copy];
        recordedType = type;
        NSLog(@"[YCYUnlock] ★ 已记录疑似开锁数据");
    }

    %orig;
}

%end

#pragma mark - 启动

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    %orig;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            createFloatButton();
        });
    });
}

%end

%ctor {
    NSLog(@"[YCYUnlock] 插件加载成功");
}

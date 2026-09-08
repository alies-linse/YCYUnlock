TARGET := iphone:clang:latest:13.0
INSTALL_TARGET_PROCESSES = UNI02A710B

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YCYUnlock

YCYUnlock_FILES = Tweak.x
YCYUnlock_CFLAGS = -fobjc-arc -Wno-error
YCYUnlock_FRAMEWORKS = UIKit CoreBluetooth Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
目标版本：iphone:clang:latest:13.0
安装目标进程 = UNI02A710B

包含 $(THEOS) /makefiles/common.mk

TWEAK_NAME = YCYUnlock

YCYUnlock_FILES = Tweak.x
YCYUnlock_CFLAGS = -fobjc-arc -Wno-错误
YCYUnlock_FRAMEWORKS = UIKit CoreBluetooth Foundation

包含 $(THEOS_MAKE_PATH) /tweak.mk

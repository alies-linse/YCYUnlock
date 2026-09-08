TARGET := iphone:clang:latest:13.0
INSTALL_TARGET_PROCESSES = UNI02A710B

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YCYUnlock

YCYUnlock_FILES = Tweak.x
YCYUnlock_CFLAGS = -fobjc-arc
YCYUnlock_FRAMEWORKS = UIKit CoreBluetooth Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

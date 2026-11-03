TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

# Dopamine-roothide: build with roothide/theos (~/theos-roothide).
THEOS = $(HOME)/theos-roothide
THEOS_PACKAGE_SCHEME = roothide

# iPhone 15 Plus over USB: run `iproxy 2222 22` first.
THEOS_DEVICE_IP ?= 127.0.0.1
THEOS_DEVICE_PORT ?= 2222

INSTALL_TARGET_PROCESSES = AppStore

include $(THEOS)/makefiles/common.mk

# Keep these paths inside the project root: a leading ../ would make every arch
# share one Logos intermediate and break parallel builds.
TWEAK_NAME = AppStoreControl
AppStoreControl_FILES = $(wildcard sources/*.x sources/*.m)
AppStoreControl_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -Wno-unused-function
AppStoreControl_FRAMEWORKS = UIKit Foundation CoreGraphics Security
AppStoreControl_LIBRARIES = substrate z

# The tweak menu opens the log, so release builds keep logging.
XLOG_RELEASE = 1
include ../../shared/XLog/XLog.mk

include $(THEOS_MAKE_PATH)/tweak.mk

# ElleKit reads the injection filter as the target process's user, so the plist
# must stay world readable (otherwise it would be root-only 600 and the tweak
# would silently fail to load).
before-package::
	chmod 644 "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/AppStoreControl.plist"

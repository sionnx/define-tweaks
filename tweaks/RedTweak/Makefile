TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = discover

# Dopamine RootHide: build with roothide/theos (~/theos-roothide).
THEOS = $(HOME)/theos-roothide
THEOS_PACKAGE_SCHEME = roothide

# iPhone 15 Plus over USB: run `iproxy 2222 22` first.
THEOS_DEVICE_IP ?= 127.0.0.1
THEOS_DEVICE_PORT ?= 2222

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RedTweak
RedTweak_FILES = $(wildcard sources/*.x sources/*.m)
RedTweak_CFLAGS = -fobjc-arc
RedTweak_FRAMEWORKS = UIKit Foundation

include ../../shared/XLog/XLog.mk
include ../../shared/XPrefs/XPrefs.mk

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

# ElleKit reads the injection filter as the target process's user, so the plist
# must stay world readable.
before-package::
	chmod 644 "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/RedTweak.plist"

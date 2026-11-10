TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = PocketPadPrefs

PocketPadPrefs_FILES = PPRootListController.m
PocketPadPrefs_FRAMEWORKS = UIKit
PocketPadPrefs_PRIVATE_FRAMEWORKS = Preferences MobileCoreServices
PocketPadPrefs_INSTALL_PATH = /Library/PreferenceBundles
PocketPadPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

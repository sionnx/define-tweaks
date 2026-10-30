TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = DockReelPrefs

DockReelPrefs_FILES = DRPRootListController.m
DockReelPrefs_FRAMEWORKS = UIKit
DockReelPrefs_PRIVATE_FRAMEWORKS = Preferences
DockReelPrefs_INSTALL_PATH = /Library/PreferenceBundles
DockReelPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

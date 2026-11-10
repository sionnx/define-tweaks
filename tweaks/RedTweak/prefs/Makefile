TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = RedTweakPrefs

RedTweakPrefs_FILES = RTPRootListController.m
RedTweakPrefs_FRAMEWORKS = UIKit
RedTweakPrefs_PRIVATE_FRAMEWORKS = Preferences
RedTweakPrefs_INSTALL_PATH = /Library/PreferenceBundles
RedTweakPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

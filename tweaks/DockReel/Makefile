TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

# Dopamine-roothide: build with roothide/theos (~/theos-roothide).
THEOS = $(HOME)/theos-roothide
THEOS_PACKAGE_SCHEME = roothide

# iPhone 15 Plus over USB: run `iproxy 2222 22` first.
THEOS_DEVICE_IP ?= 127.0.0.1
THEOS_DEVICE_PORT ?= 2222

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DockReel
DockReel_FILES = Tweak.x DRDockScrollView.m DRDebug.m
DockReel_CFLAGS = -fobjc-arc
DockReel_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

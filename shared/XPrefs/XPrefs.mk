# Adds XPrefs to the tweak being built. Include it after XLog.mk and before
# tweak.mk.

XPREFS_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Absolute on purpose, for the same reason as in XLog.mk.
$(TWEAK_NAME)_FILES += $(XPREFS_DIR)/XPrefs.m
$(TWEAK_NAME)_CFLAGS += -I$(XPREFS_DIR)

# jbroot() comes from libroothide; other schemes get the inline stub from
# roothide.h and need no library.
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
$(TWEAK_NAME)_LIBRARIES += roothide
endif

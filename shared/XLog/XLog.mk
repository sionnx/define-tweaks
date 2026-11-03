# Adds XLog to the tweak being built. Include it after the tweak's own _FILES
# and _CFLAGS assignments and before tweak.mk.
#
# Logging is compiled out of FINALPACKAGE builds unless the tweak sets
# XLOG_RELEASE = 1 before this include.

XLOG_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

ifeq ($(FINALPACKAGE)/$(XLOG_RELEASE),1/)
XLOG_ENABLED := 0
else
XLOG_ENABLED := 1
endif

# Absolute on purpose: Theos appends this path to the per-arch object directory,
# and a leading ../ would make every arch share one object file.
$(TWEAK_NAME)_FILES += $(XLOG_DIR)/XLog.m
$(TWEAK_NAME)_CFLAGS += -I$(XLOG_DIR) -DXLOG_ENABLED=$(XLOG_ENABLED) -DXLOG_TWEAK_NAME=\"$(TWEAK_NAME)\"

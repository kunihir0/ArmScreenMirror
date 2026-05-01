TARGET := iphone:clang:latest:11.0
ARCHS  := arm64 arm64e

ifeq ($(THEOS),)
ifneq ($(wildcard $(HOME)/theos/makefiles/common.mk),)
THEOS := $(HOME)/theos
export THEOS
else
$(error Theos no encontrado. git clone --recursive https://github.com/theos/theos.git ~/theos)
endif
endif

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = ScreenMirrorControl

ScreenMirrorControl_FILES = \
    src/main.m \
    src/AppDelegate.m \
    src/ViewController.m

ScreenMirrorControl_FRAMEWORKS = UIKit Foundation CoreFoundation
ScreenMirrorControl_RESOURCE_DIRS = Resources
ScreenMirrorControl_CFLAGS  = -fobjc-arc -Wno-deprecated-declarations -Wno-nullability-completeness -Wno-error=unguarded-availability-new

include $(THEOS_MAKE_PATH)/application.mk

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
APP_BUNDLE := .theos/_/var/jb/Applications/ScreenMirrorControl.app
else
APP_BUNDLE := .theos/_/Applications/ScreenMirrorControl.app
endif

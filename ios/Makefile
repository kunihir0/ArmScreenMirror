TARGET := iphone:clang:latest:11.0
ARCHS  := arm64 arm64e

ifeq ($(THEOS),)
ifneq ($(wildcard $(HOME)/theos/makefiles/common.mk),)
THEOS := $(HOME)/theos
export THEOS
else
$(error Theos no encontrado. Instálalo con: git clone --recursive https://github.com/theos/theos.git ~/theos)
endif
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ScreenMirror

ScreenMirror_FILES = \
    src/Tweak.x \
    src/ScreenCapture.m \
    src/VideoEncoder.m \
    src/NetworkClient.m \
    src/TouchInjector.m \
    src/Crypto.m \
    src/X25519.c

ScreenMirror_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore CoreVideo CoreMedia VideoToolbox IOSurface Security
ScreenMirror_CFLAGS  = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-nullability-completeness -Wno-error=unguarded-availability-new
ScreenMirror_LDFLAGS = -Wl,-segalign,4000

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"

APP_NAME := ScreenMirrorServer
BUILD    := .build/release/$(APP_NAME)
APP_DIR  := $(APP_NAME).app
APP_BIN  := $(APP_DIR)/Contents/MacOS/$(APP_NAME)

.PHONY: all build app clean run

all: app

build:
	swift build -c release

app: build
	@rm -rf $(APP_DIR)
	@mkdir -p $(APP_DIR)/Contents/MacOS
	@mkdir -p $(APP_DIR)/Contents/Resources
	@cp $(BUILD) $(APP_BIN)
	@cp Resources/Info.plist $(APP_DIR)/Contents/Info.plist
	@codesign --force --deep --sign - $(APP_DIR) || true
	@echo "==> $(APP_DIR) listo"

run: app
	open $(APP_DIR)

clean:
	rm -rf .build $(APP_DIR)

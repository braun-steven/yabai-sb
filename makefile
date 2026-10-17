MACOS_MIN      = 27.0
BUILD_PATH     = ./bin
DOC_PATH       = ./doc
SCRIPT_PATH    = ./scripts
ASSET_PATH     = ./assets
SMP_PATH       = ./examples
ARCH_PATH      = ./archive
OSAX_SRC       = ./osax/payload_bin.c ./osax/loader_bin.c
OSAX_PATH      = ./osax
OSAX_FLAGS     = -O3 -mmacosx-version-min=$(MACOS_MIN) -arch arm64e -fno-objc-arc -Wall -Wextra -Werror
OSAX_WORK      = .build/osax/swift
OSAX_NATIVE    = $(OSAX_PATH)/payload.m $(OSAX_PATH)/core/api/API.c
SWIFT          ?= xcrun swift
SWIFT_FLAGS    ?=
SWIFT_BUILD    = $(SWIFT) build --product yabai --arch arm64 $(SWIFT_FLAGS)
BUILD_FLAGS    = --configuration debug

# Package.swift reads it to stamp the right SDK version into the binary
export SDKROOT := $(shell xcrun --show-sdk-path)

.PHONY: all asan tsan install prepare test osax-test osax-payload man icon archive publish sign clean-build clean

# Build variants publish to the same bin/yabai; do not run them concurrently with make -j.
.NOTPARALLEL:
.DELETE_ON_ERROR:
.DEFAULT_GOAL := all

asan: BUILD_FLAGS += --scratch-path .build/asan --sanitize=address --sanitize=undefined
tsan: BUILD_FLAGS += --scratch-path .build/tsan --sanitize=thread --sanitize=undefined
install: BUILD_FLAGS = --configuration release

# SwiftPM owns compilation and optimization. Publish only after a successful build, keeping the
# previous executable (and other bin/ artifacts) available if compilation or copying fails.
all install asan tsan: prepare
	$(SWIFT_BUILD) $(BUILD_FLAGS)
	mkdir -p $(BUILD_PATH)
	cp "$$($(SWIFT_BUILD) $(BUILD_FLAGS) --show-bin-path)/yabai" $(BUILD_PATH)/.yabai.tmp
	mv -f $(BUILD_PATH)/.yabai.tmp $(BUILD_PATH)/yabai

# Swift Build 6.4 does not compile plugin-generated C sources. This is the only preparation
# outside SwiftPM; it is also available before direct swift build/run/test or opening the package.
prepare: $(OSAX_SRC)

test: prepare
	$(SWIFT) test $(SWIFT_FLAGS)

osax-test:
	$(SWIFT) test --package-path osax $(SWIFT_FLAGS)

# Build the standalone arm64e payload without installing or injecting it.
osax-payload: $(OSAX_WORK)/payload

$(OSAX_WORK)/payload: makefile $(OSAX_NATIVE) $(OSAX_PATH)/core/swift/Core.swift $(OSAX_PATH)/common.h $(OSAX_PATH)/arm64_payload.m $(OSAX_PATH)/core/api/include/OSAXCore.h $(OSAX_PATH)/core/api/include/module.modulemap $(OSAX_PATH)/core/IO.h
	mkdir -p $(OSAX_WORK)
	xcrun clang -c $(OSAX_PATH)/payload.m $(OSAX_FLAGS) -o $(OSAX_WORK)/native.o
	xcrun clang -c $(OSAX_PATH)/core/api/API.c $(OSAX_FLAGS) -o $(OSAX_WORK)/api.o
	xcrun swiftc -emit-library -O -swift-version 6 -warnings-as-errors -target arm64e-apple-macosx$(MACOS_MIN) -module-cache-path .build/osax/module-cache -I $(OSAX_PATH)/core/api/include $(OSAX_PATH)/core/swift/Core.swift $(OSAX_WORK)/native.o $(OSAX_WORK)/api.o -o $@ -F/System/Library/PrivateFrameworks -framework SkyLight -framework Foundation -framework Carbon

$(OSAX_PATH)/payload_bin.c: $(OSAX_WORK)/payload
	xxd -i -a -n __osax_payload $(OSAX_WORK)/payload $@

$(OSAX_WORK)/loader: makefile $(OSAX_PATH)/loader.m $(OSAX_PATH)/bootstrap.S $(OSAX_PATH)/common.h $(OSAX_PATH)/core/IO.h
	mkdir -p $(OSAX_WORK)
	xcrun clang $(OSAX_PATH)/loader.m $(OSAX_PATH)/bootstrap.S $(OSAX_FLAGS) -o $@ -framework Cocoa

$(OSAX_PATH)/loader_bin.c: $(OSAX_WORK)/loader
	xxd -i -a -n __osax_loader $(OSAX_WORK)/loader $@

man:
	asciidoctor -b manpage $(DOC_PATH)/yabai.asciidoc -o $(DOC_PATH)/yabai.1

icon:
	python3 $(SCRIPT_PATH)/seticon.py $(ASSET_PATH)/icon/2x/icon-512px@2x.png $(BUILD_PATH)/yabai

publish:
	sed -i '' "s/^VERSION=.*/VERSION=\"$(shell $(BUILD_PATH)/yabai --version | cut -d "v" -f 2)\"/" $(SCRIPT_PATH)/install.sh
	sed -i '' "s/^EXPECTED_HASH=.*/EXPECTED_HASH=\"$(shell shasum -a 256 $(BUILD_PATH)/$(shell $(BUILD_PATH)/yabai --version).tar.gz | cut -d " " -f 1)\"/" $(SCRIPT_PATH)/install.sh

archive: man install
	$(MAKE) sign
	$(MAKE) icon
	rm -rf $(ARCH_PATH)
	mkdir -p $(ARCH_PATH)/bin
	cp $(BUILD_PATH)/yabai $(ARCH_PATH)/bin/
	cp -r $(DOC_PATH) $(ARCH_PATH)/
	cp -r $(SMP_PATH) $(ARCH_PATH)/
	tar -cvzf $(BUILD_PATH)/$(shell $(BUILD_PATH)/yabai --version).tar.gz $(ARCH_PATH)
	rm -rf $(ARCH_PATH)

sign:
	codesign -fs "yabai-cert" $(BUILD_PATH)/yabai

clean-build:
	rm -rf $(BUILD_PATH)

clean: clean-build
	rm -rf .build osax/.build
	rm -f $(OSAX_SRC)

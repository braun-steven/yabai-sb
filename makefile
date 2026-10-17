MACOS_MIN      = 27.0
FRAMEWORK_PATH = -F/System/Library/PrivateFrameworks
BUILD_PATH     = ./bin
DOC_PATH       = ./doc
SCRIPT_PATH    = ./scripts
ASSET_PATH     = ./assets
SMP_PATH       = ./examples
ARCH_PATH      = ./archive
OSAX_SRC       = ./osax/payload_bin.c ./osax/loader_bin.c
OSAX_PATH      = ./osax
OSAX_FLAGS     = -O3 -mmacosx-version-min=$(MACOS_MIN) -arch arm64e -fno-objc-arc -Wall -Wextra -Werror
# Keep the existing output path; there is only one payload implementation.
OSAX_WORK      = .build/osax/swift
OSAX_NATIVE    = $(OSAX_PATH)/payload.m $(OSAX_PATH)/core/api/API.c
ARCHS          = arm64
SWIFT_BUILD    = swift build --product yabai $(foreach arch,$(ARCHS),--arch $(arch))
VARIANT_FLAGS  =
BINS           = $(BUILD_PATH)/yabai

# Package.swift reads it to stamp the right SDK version into the binary
export SDKROOT := $(shell xcrun --show-sdk-path)

.PHONY: all asan tsan install test osax-test osax-payload man icon archive publish sign clean-build clean FORCE

all: $(BINS)

asan: VARIANT_FLAGS = --sanitize=address --sanitize=undefined
asan: $(BINS)

tsan: VARIANT_FLAGS = --sanitize=thread --sanitize=undefined
tsan: $(BINS)

install: VARIANT_FLAGS = -c release -Xswiftc -warnings-as-errors
install: $(BINS)

# swift test needs the generated OSAX sources: they are sources of the OSAX target
test: $(OSAX_SRC)
	swift test

osax-test:
	swift test --package-path osax

# Build the standalone arm64e payload without installing or injecting it.
osax-payload: $(OSAX_WORK)/payload

$(OSAX_WORK)/payload: $(OSAX_NATIVE) $(OSAX_PATH)/core/swift/Core.swift $(OSAX_PATH)/common.h $(OSAX_PATH)/arm64_payload.m $(OSAX_PATH)/core/api/include/OSAXCore.h $(OSAX_PATH)/core/IO.h
	mkdir -p $(OSAX_WORK)
	xcrun clang -c $(OSAX_PATH)/payload.m $(OSAX_FLAGS) -o $(OSAX_WORK)/native.o
	xcrun clang -c $(OSAX_PATH)/core/api/API.c $(OSAX_FLAGS) -o $(OSAX_WORK)/api.o
	xcrun swiftc -emit-library -O -swift-version 6 -warnings-as-errors -target arm64e-apple-macosx$(MACOS_MIN) -module-cache-path .build/osax/module-cache -I $(OSAX_PATH)/core/api/include $(OSAX_PATH)/core/swift/Core.swift $(OSAX_WORK)/native.o $(OSAX_WORK)/api.o -o $@ -F/System/Library/PrivateFrameworks -framework SkyLight -framework Foundation -framework Carbon

# payload.m #includes these, so a pattern/offset update must rebuild the payload
$(OSAX_PATH)/payload_bin.c: $(OSAX_WORK)/payload
	xxd -i -a -n __osax_payload $(OSAX_WORK)/payload $@

$(OSAX_PATH)/loader_bin.c: $(OSAX_PATH)/loader.m $(OSAX_PATH)/bootstrap.S $(OSAX_PATH)/common.h $(OSAX_PATH)/core/IO.h
	xcrun clang $(OSAX_PATH)/loader.m $(OSAX_PATH)/bootstrap.S $(OSAX_FLAGS) -o $(OSAX_PATH)/loader -framework Cocoa
	xxd -i -a -n __osax_loader $(OSAX_PATH)/loader $@
	rm -f $(OSAX_PATH)/loader

man:
	asciidoctor -b manpage $(DOC_PATH)/yabai.asciidoc -o $(DOC_PATH)/yabai.1

icon:
	python3 $(SCRIPT_PATH)/seticon.py $(ASSET_PATH)/icon/2x/icon-512px@2x.png $(BUILD_PATH)/yabai

publish:
	sed -i '' "60s/^VERSION=.*/VERSION=\"$(shell $(BUILD_PATH)/yabai --version | cut -d "v" -f 2)\"/" $(SCRIPT_PATH)/install.sh
	sed -i '' "61s/^EXPECTED_HASH=.*/EXPECTED_HASH=\"$(shell shasum -a 256 $(BUILD_PATH)/$(shell $(BUILD_PATH)/yabai --version).tar.gz | cut -d " " -f 1)\"/" $(SCRIPT_PATH)/install.sh

archive: man install sign icon
	rm -rf $(ARCH_PATH)
	mkdir -p $(ARCH_PATH)
	cp -r $(BUILD_PATH) $(ARCH_PATH)/
	cp -r $(DOC_PATH) $(ARCH_PATH)/
	cp -r $(SMP_PATH) $(ARCH_PATH)/
	tar -cvzf $(BUILD_PATH)/$(shell $(BUILD_PATH)/yabai --version).tar.gz $(ARCH_PATH)
	rm -rf $(ARCH_PATH)

sign:
	codesign -fs "yabai-cert" $(BUILD_PATH)/yabai

clean-build:
	rm -rf $(BUILD_PATH)

clean: clean-build
	rm -rf .build
	rm -f $(OSAX_SRC)

# SwiftPM builds the binary (Package.swift) incrementally in .build; the variants only differ in VARIANT_FLAGS.
# bin/ is replaced on every build, so it never holds the binary of another variant.
$(BUILD_PATH)/yabai: $(OSAX_SRC) FORCE
	rm -rf $(BUILD_PATH)
	mkdir -p $(BUILD_PATH)
	$(SWIFT_BUILD) $(VARIANT_FLAGS)
	cp "$$($(SWIFT_BUILD) $(VARIANT_FLAGS) --show-bin-path)/yabai" $@

FORCE:

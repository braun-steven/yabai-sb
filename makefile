BUILD_PATH     = ./bin
DOC_PATH       = ./doc
SCRIPT_PATH    = ./scripts
ASSET_PATH     = ./assets
SMP_PATH       = ./examples
ARCH_PATH      = ./archive
# SWIFT selects only the outer driver. DEVELOPER_DIR/TOOLCHAINS select tools for both builds.
SWIFT          ?= xcrun swift
SWIFT_FLAGS    ?=
SWIFT_BUILD    = $(SWIFT) build --product yabai --arch arm64 $(SWIFT_FLAGS)
BUILD_FLAGS    = --configuration debug

# Package.swift reads it to stamp the right SDK version into the binary
export SDKROOT ?= $(shell xcrun --sdk macosx --show-sdk-path)

.PHONY: all asan tsan install prepare test ci-quick ci coverage check-build osax-test osax-payload man icon archive publish sign clean-build clean

# Build variants publish to the same bin/yabai; do not run them concurrently with make -j.
.NOTPARALLEL:
.DELETE_ON_ERROR:
.DEFAULT_GOAL := all

asan: BUILD_FLAGS += --scratch-path .build/asan --sanitize=address --sanitize=undefined
tsan: BUILD_FLAGS += --scratch-path .build/tsan --sanitize=thread --sanitize=undefined
install: BUILD_FLAGS = --configuration release

# SwiftPM owns compilation and optimization. Publish only after a successful build, keeping the
# previous executable (and other bin/ artifacts) available if compilation or copying fails.
all install asan tsan:
	$(SWIFT_BUILD) $(BUILD_FLAGS)
	mkdir -p $(BUILD_PATH)
	cp "$$($(SWIFT_BUILD) $(BUILD_FLAGS) --show-bin-path)/yabai" $(BUILD_PATH)/.yabai.tmp
	mv -f $(BUILD_PATH)/.yabai.tmp $(BUILD_PATH)/yabai

# Optional: build just the embedded scripting addition through SwiftPM.
prepare:
	$(SWIFT) build --target OSAX $(SWIFT_FLAGS)

test:
	$(SWIFT) test $(SWIFT_FLAGS)

# CI gates: concise per-step output, full logs in .build/ci/. quick: build and test; full: adds release build, osax-test, check-build.
ci-quick:
	SWIFT="$(SWIFT)" SWIFT_FLAGS="$(SWIFT_FLAGS)" bash $(SCRIPT_PATH)/ci.sh quick

ci:
	SWIFT="$(SWIFT)" SWIFT_FLAGS="$(SWIFT_FLAGS)" bash $(SCRIPT_PATH)/ci.sh full

# Line coverage of Sources/ per file; COVERAGE_FILTER is an extended regex of the files to show.
coverage:
	SWIFT="$(SWIFT)" SWIFT_FLAGS="$(SWIFT_FLAGS)" bash $(SCRIPT_PATH)/coverage.sh "$(COVERAGE_FILTER)"

check-build:
	python3 $(SCRIPT_PATH)/check-build.py --swift "$(SWIFT)"

osax-test:
	$(SWIFT) test --package-path osax $(SWIFT_FLAGS)

# Build the standalone arm64e payload without installing or injecting it.
osax-payload:
	bash $(SCRIPT_PATH)/build-osax.sh .build/osax/swift

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
	rm -f osax/payload_bin.c osax/loader_bin.c

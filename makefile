MACOS_MIN      = 11.0
FRAMEWORK_PATH = -F/System/Library/PrivateFrameworks
FRAMEWORK      = -framework Carbon -framework Cocoa -framework CoreServices -framework CoreVideo -framework SkyLight
WARN_FLAGS     = -Wall -Wextra -Wstrict-prototypes -Wimplicit-fallthrough -Wnull-dereference
COMMON_FLAGS   = -std=c11 $(WARN_FLAGS) -fvisibility=hidden -mmacosx-version-min=$(MACOS_MIN) -fno-objc-arc
CLI_FLAGS      =
VARIANT_FLAGS  = -g -O0
BUILD_FLAGS    = $(COMMON_FLAGS) $(VARIANT_FLAGS) -arch x86_64 -arch arm64 -sectcreate __TEXT __info_plist $(INFO_PLIST)
BUILD_PATH     = ./bin
DOC_PATH       = ./doc
SCRIPT_PATH    = ./scripts
ASSET_PATH     = ./assets
SMP_PATH       = ./examples
ARCH_PATH      = ./archive
OSAX_SRC       = ./src/osax/payload_bin.c ./src/osax/loader_bin.c
YABAI_SRC      = ./src/manifest.m $(OSAX_SRC)
OSAX_PATH      = ./src/osax
OSAX_FLAGS     = -O3 -mmacosx-version-min=$(MACOS_MIN) -arch x86_64 -arch arm64e
INFO_PLIST     = $(ASSET_PATH)/Info.plist
BINS           = $(BUILD_PATH)/yabai

.PHONY: all asan tsan install test analyze man icon archive publish sign clean-build clean FORCE

all: $(BINS)

asan: VARIANT_FLAGS = -g -O0 -fsanitize=address,undefined
asan: $(BINS)

tsan: VARIANT_FLAGS = -g -O0 -fsanitize=thread,undefined
tsan: $(BINS)

install: VARIANT_FLAGS = -DNDEBUG -O3
install: $(BINS)

test:
	$(MAKE) -C tests

# every source file is #included into manifest.m, so the analyzer must be told to analyze included files
analyze:
	xcrun clang --analyze -Xclang -analyzer-opt-analyze-headers -Xclang -analyzer-output=text $(COMMON_FLAGS) -arch arm64 $(FRAMEWORK_PATH) ./src/manifest.m -o /dev/null

# payload.m #includes these, so a pattern/offset update must rebuild the payload
$(OSAX_PATH)/payload_bin.c: $(OSAX_PATH)/payload.m $(OSAX_PATH)/common.h $(OSAX_PATH)/x64_payload.m $(OSAX_PATH)/arm64_payload.m ./src/misc/hashtable.h
	xcrun clang $(OSAX_PATH)/payload.m -shared -fPIC $(OSAX_FLAGS) -o $(OSAX_PATH)/payload $(FRAMEWORK_PATH) -framework SkyLight -framework Foundation -framework Carbon
	xxd -i -a $(OSAX_PATH)/payload $@
	rm -f $(OSAX_PATH)/payload

$(OSAX_PATH)/loader_bin.c: $(OSAX_PATH)/loader.m
	xcrun clang $(OSAX_PATH)/loader.m $(OSAX_FLAGS) -o $(OSAX_PATH)/loader -framework Cocoa
	xxd -i -a $(OSAX_PATH)/loader $@
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
	rm -f $(OSAX_SRC)

# always relink from scratch: the variants share one output path, and the unity build takes seconds.
# The old bin/ (incl. a stale yabai.dSYM) is removed here instead of by a clean-build prerequisite,
# which would race with the compile under make -j.
$(BUILD_PATH)/yabai: $(YABAI_SRC) FORCE
	rm -rf $(BUILD_PATH)
	mkdir -p $(BUILD_PATH)
	xcrun clang $(YABAI_SRC) $(BUILD_FLAGS) $(CLI_FLAGS) $(FRAMEWORK_PATH) $(FRAMEWORK) -o $@

FORCE:

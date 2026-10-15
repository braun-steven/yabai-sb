FRAMEWORK_PATH = -F/System/Library/PrivateFrameworks
FRAMEWORK      = -framework Carbon -framework Cocoa -framework CoreServices -framework SkyLight
# same language and warning flags as ../makefile; -DTESTS removes main() and the code only it calls, hence -Wno-unused-function.
# Tests run under ASan/UBSan, and any undefined behavior aborts the run.
TEST_FLAGS     = -std=c11 -Wall -Wextra -Wstrict-prototypes -Wimplicit-fallthrough -Wnull-dereference -Wno-unused-function \
                 -g -O0 -fno-objc-arc -mmacosx-version-min=27.0 \
                 -fsanitize=address,undefined -fno-sanitize-recover=undefined
# the Swift code of the daemon (all of ../Sources/Yabai but main.swift) as one object for the host architecture. It sees the
# C headers as the modules YabaiC (../src/include/module.modulemap) and CPrivate, like in Package.swift, and imports
# YabaiCore, which is built first as its own module and object.
CPRIVATE_PATH  = ../Sources/CPrivate
CORE_SRC       = $(wildcard ../Sources/YabaiCore/*.swift)
SWIFT_SRC      = $(filter-out %/main.swift,$(wildcard ../Sources/Yabai/*.swift ../Sources/Yabai/*/*.swift))
SWIFTC_FLAGS   = -swift-version 6 -parse-as-library -wmo -emit-object -g -Onone -sanitize=address -target $(shell uname -m)-apple-macos27.0
CORE_FLAGS     = $(SWIFTC_FLAGS) -module-name YabaiCore -emit-module-path ./bin/YabaiCore.swiftmodule
SWIFT_FLAGS    = $(SWIFTC_FLAGS) -module-name Yabai -I ./bin -I ../src/include -I $(CPRIVATE_PATH)/include -Xcc -DTESTS -Xcc -DPROFILE=1
SWIFT_LINK     = -L$(shell xcrun --show-sdk-path)/usr/lib/swift -L$(shell dirname $(shell xcrun -f swiftc))/../lib/swift/macosx -Wl,-rpath,/usr/lib/swift

.PHONY: clean build run all

all: run

clean:
	rm -rf ./bin

build:
	rm -rf ./bin
	mkdir -p ./bin
	xcrun swiftc $(CORE_SRC) $(CORE_FLAGS) -o ./bin/yabai_core.o
	xcrun swiftc $(SWIFT_SRC) $(SWIFT_FLAGS) -o ./bin/yabai_swift.o
	xcrun clang ./src/tests.m $(CPRIVATE_PATH)/CPrivate.c ./bin/yabai_core.o ./bin/yabai_swift.o -o ./bin/tests -DTESTS -DPROFILE=1 -I $(CPRIVATE_PATH)/include $(TEST_FLAGS) $(FRAMEWORK_PATH) $(FRAMEWORK) $(SWIFT_LINK)

run: build
	./bin/tests

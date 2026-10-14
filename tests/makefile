FRAMEWORK_PATH = -F/System/Library/PrivateFrameworks
FRAMEWORK      = -framework Carbon -framework Cocoa -framework CoreServices -framework CoreVideo -framework SkyLight
# same language and warning flags as ../makefile; -DTESTS removes main() and the code only it calls, hence -Wno-unused-function.
# Tests run under ASan/UBSan, and any undefined behavior aborts the run.
TEST_FLAGS     = -std=c11 -Wall -Wextra -Wstrict-prototypes -Wimplicit-fallthrough -Wnull-dereference -Wno-unused-function \
                 -g -O0 -fno-objc-arc -mmacosx-version-min=11.0 \
                 -fsanitize=address,undefined -fno-sanitize-recover=undefined
# the Swift side of the glass tab bars, built for the host architecture like the tests (see ../makefile)
SWIFT_FLAGS    = -swift-version 6 -parse-as-library -module-name yabai -import-objc-header ../src/tab_bar_glass.h -disable-bridging-pch \
                 -emit-object -g -Onone -sanitize=address -target $(shell uname -m)-apple-macos11.0
SWIFT_LINK     = -L$(shell xcrun --show-sdk-path)/usr/lib/swift -L$(shell dirname $(shell xcrun -f swiftc))/../lib/swift/macosx -Wl,-rpath,/usr/lib/swift

.PHONY: clean build run all

all: run

clean:
	rm -rf ./bin

build:
	rm -rf ./bin
	mkdir -p ./bin
	xcrun swiftc ../src/tab_bar_glass.swift $(SWIFT_FLAGS) -o ./bin/tab_bar_glass.o
	xcrun clang ./src/tests.m ./bin/tab_bar_glass.o -o ./bin/tests -DTESTS -DPROFILE=1 $(TEST_FLAGS) $(FRAMEWORK_PATH) $(FRAMEWORK) $(SWIFT_LINK)

run: build
	./bin/tests

FRAMEWORK_PATH = -F/System/Library/PrivateFrameworks
FRAMEWORK      = -framework Carbon -framework Cocoa -framework CoreServices -framework CoreVideo -framework SkyLight
# same language and warning flags as ../makefile; -DTESTS removes main() and the code only it calls, hence -Wno-unused-function.
# Tests run under ASan/UBSan, and any undefined behavior aborts the run.
TEST_FLAGS     = -std=c11 -Wall -Wextra -Wstrict-prototypes -Wimplicit-fallthrough -Wnull-dereference -Wno-unused-function \
                 -g -O0 -fno-objc-arc -mmacosx-version-min=11.0 \
                 -fsanitize=address,undefined -fno-sanitize-recover=undefined

.PHONY: clean build run all

all: run

clean:
	rm -rf ./bin

build:
	rm -rf ./bin
	mkdir -p ./bin
	xcrun clang ./src/tests.m -o ./bin/tests -DTESTS -DPROFILE=1 $(TEST_FLAGS) $(FRAMEWORK_PATH) $(FRAMEWORK)

run: build
	./bin/tests

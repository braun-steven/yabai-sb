#ifndef YABAI_C_H
#define YABAI_C_H

//
// NOTE: Every header of the unity build, in the order manifest.m needs them. Swift imports them as the module
// YabaiC (module.modulemap) while the port moves code from C to Swift (doc/swift-port.md).
//

#include <objc/objc-runtime.h>
#include <Carbon/Carbon.h>
#include <Cocoa/Cocoa.h>
#include <CoreVideo/CoreVideo.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <mach-o/swap.h>
#include <bootstrap.h>

#include <arm_neon.h>

// the entry point of the daemon and the client in yabai.c, called by main.swift
int yabai_main(int argc, char **argv);

#include <stdio.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <dirent.h>
#include <stdbool.h>
#include <assert.h>
#include <fcntl.h>
#include <regex.h>
#include <execinfo.h>
#include <signal.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <poll.h>
#include <semaphore.h>
#include <pthread.h>
#include <pwd.h>
#include <spawn.h>
#include <libproc.h>
#include <dlfcn.h>

#include <CPrivate.h>
#include "../misc/macros.h"
#include "../misc/memory_pool.h"
#include "../misc/ts.h"
//#include "../misc/autorelease.h"
#include "../misc/notify.h"
#include "../misc/log.h"
#include "../misc/helpers.h"
#include "../misc/timer.h"
#include "../misc/macho_dlsym.h"
#include "../misc/sbuffer.h"
#include "../misc/label.h"
#include "../misc/hashtable.h"
#include "../misc/service.h"

#include "../osax/common.h"

#include "../view.h"
#include "../tab_bar_glass.h"
#include "../tab_bar.h"
#include "../tree.h"
#include "../sa.h"
#include "../event_loop.h"
#include "../event_signal.h"
#include "../workspace.h"
#include "../rule.h"
#include "../message.h"
#include "../display.h"
#include "../space.h"
#include "../window.h"
#include "../process_manager.h"
#include "../application.h"
#include "../display_manager.h"
#include "../space_layout.h"
#include "../space_manager.h"
#include "../window_manager.h"
#include "../border.h"
#include "../mouse_handler.h"


// the entry point of the daemon and the client in yabai.c, called by main.swift
int yabai_main(int argc, char **argv);

#endif

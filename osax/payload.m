#include <Foundation/Foundation.h>

#if __has_feature(objc_arc)
#error                                                                         \
    "payload.m uses manual retain/release and must be compiled without -fobjc-arc"
#endif

#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/vm_map.h>
#include <mach/vm_page_size.h>
#include <objc/message.h>
#include <objc/runtime.h>

#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <libkern/OSCacheControl.h>
#include <pwd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "common.h"
#include "core/IO.h"
#include "core/api/include/OSAXCore.h"

#include "arm64_payload.m"
#include <ptrauth.h>
#include <uuid/uuid.h>

#define page_align(addr)                                                       \
  (vm_address_t)((uintptr_t)(addr) & (~(vm_page_size - 1)))
#define unpack(v)                                                              \
  memcpy(&v, message, sizeof(v));                                              \
  message += sizeof(v)

extern int SLSMainConnectionID(void);
extern OSStatus SLSMoveWindowWithGroup(int cid, uint32_t wid, CGPoint *point);
extern CGError SLSReassociateWindowsSpacesByGeometry(int cid,
                                                     CFArrayRef window_list);
extern CGError SLSSetWindowTags(int cid, uint32_t wid, uint64_t *tags,
                                size_t tag_size);
extern CGError SLSClearWindowTags(int cid, uint32_t wid, uint64_t *tags,
                                  size_t tag_size);
extern CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *frame);
extern CGError SLSGetWindowTransform(int cid, uint32_t wid,
                                     CGAffineTransform *t);
extern CGError SLSSetWindowTransform(int cid, uint32_t wid,
                                     CGAffineTransform t);
extern CGError SLSOrderWindow(int cid, uint32_t wid, int order,
                              uint32_t rel_wid);
extern void SLSManagedDisplaySetCurrentSpace(int cid, CFStringRef display_ref,
                                             uint64_t sid);
extern uint64_t SLSManagedDisplayGetCurrentSpace(int cid,
                                                 CFStringRef display_ref);
extern CFStringRef SLSCopyManagedDisplayForSpace(int cid, uint64_t sid);
extern void SLSMoveWindowsToManagedSpace(int cid, CFArrayRef window_list,
                                         uint64_t sid);
extern void SLSShowSpaces(int cid, CFArrayRef space_list);
extern void SLSHideSpaces(int cid, CFArrayRef space_list);
extern CFTypeRef SLSTransactionCreate(int cid);
extern CGError SLSTransactionCommit(CFTypeRef transaction, int synchronous);
extern CGError SLSTransactionOrderWindowGroup(CFTypeRef transaction,
                                              uint32_t wid, int order,
                                              uint32_t rel_wid);
extern CGError SLSSetWindowSubLevel(int cid, uint32_t wid, int level);

static id dock_spaces;
static id dp_desktop_picture_manager;
static uint64_t add_space_fp;
static uint64_t remove_space_fp;
static uint64_t move_space_fp;
static uint64_t animation_time_addr;
static bool animation_time_patched;

static int daemon_sockfd;

static uint64_t text_start, text_end;

// Only inspect readable mapped storage, and only message objects whose class is
// registered with the runtime. A byte-pattern hit is not enough to treat an
// arbitrary decoded pointer as an object.
static bool readable_address(uint64_t address, size_t size) {
  mach_vm_address_t region = address;
  mach_vm_size_t length = 0;
  vm_region_basic_info_data_64_t info;
  mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
  mach_port_t object = MACH_PORT_NULL;
  kern_return_t result = mach_vm_region(
      mach_task_self(), &region, &length, VM_REGION_BASIC_INFO_64,
      (vm_region_info_t)&info, &count, &object);
  if (object)
    mach_port_deallocate(mach_task_self(), object);
  return result == KERN_SUCCESS && (info.protection & VM_PROT_READ) &&
         region <= address && address - region <= length &&
         size <= length - (address - region);
}

static id validated_object(uint64_t storage, SEL selector) {
  if ((storage & 7) || !readable_address(storage, sizeof(id)))
    return nil;
  id object = *(id *)storage;
  if (!object || !readable_address((uintptr_t)object, sizeof(void *)))
    return nil;
  Class candidate = object_getClass(object);
  unsigned count = 0;
  Class *classes = objc_copyClassList(&count);
  bool known = false;
  for (unsigned i = 0; i < count; ++i) {
    if (classes[i] == candidate) {
      known = true;
      break;
    }
  }
  free(classes);
  return known && [object respondsToSelector:selector] ? object : nil;
}

static uint64_t hex_find_seq(uint64_t address, const char *pattern) {
  if (!address || !pattern || address < text_start || address >= text_end)
    return 0;
  size_t length = (size_t)(text_end - address);
  if (length > 0x1286a0)
    length = 0x1286a0;
  size_t offset, count;
  if (!sa_pattern_find_unique_aligned((uint8_t *)address, length, pattern,
                                      address, &offset, &count)) {
    if (count == 1) {
      NSLog(@"[yabai-sa] rejecting unaligned instruction match");
      return 0;
    }
    NSLog(@"[yabai-sa] pattern at 0x%llx has %zu matches; rejecting "
          @"missing/ambiguous function",
          address, count);
    return 0;
  }
  return address + offset;
}

static id find_instance(uint64_t address, const char *pattern, SEL selector,
                        bool alternate) {
  if (address < text_start || address >= text_end)
    return nil;
  size_t length = (size_t)(text_end - address);
  if (length > 0x1286a0)
    length = 0x1286a0;
  size_t offsets[32];
  size_t count =
      sa_pattern_scan((uint8_t *)address, length, pattern, offsets, 32);
  if (count > 32)
    return nil;
  id result = nil;
  for (size_t i = 0; i < count; ++i) {
    uint64_t pc = address + offsets[i], storage;
    if (pc > text_end - 8 || (pc & 3))
      continue;
    uint32_t instructions[2];
    memcpy(instructions, (void *)pc, sizeof(instructions));
    if (!sa_decode_adrp_add(instructions[0], instructions[1], pc, &storage))
      continue;
    id candidate = validated_object(storage, selector);
    if (candidate && selector == @selector(spacesForDisplay:) &&
        (!class_getInstanceVariable(object_getClass(candidate),
                                    "_displaySpaces") ||
         ![candidate
             respondsToSelector:@selector(currentSpaceForDisplayUUID:)] ||
         ![candidate respondsToSelector:@selector(displayIDForSpace:)]))
      candidate = nil;
    // NOTE: DPPM may live eight bytes before the usual slot (the historical
    // Sonoma fallback).
    if (!candidate && alternate && storage >= 8)
      candidate = validated_object(storage - 8, selector);
    NSLog(@"[yabai-sa] instance pattern 0x%llx -> 0x%llx %@", pc, storage,
          candidate ? @"valid" : @"rejected");
    if (!candidate)
      continue;
    if (result && result != candidate) {
      NSLog(
          @"[yabai-sa] multiple valid instance targets; disabling capability");
      return nil;
    }
    result = candidate;
  }
  return [result retain];
}

// NOTE: Dock builds whose animation instruction (get_fix_animation_pattern) was
// validated, see the Dock inspection in doc/osax-prototypes.md and "Adding a
// Dock build" in doc/payload-updates.md. Other builds keep their instruction.
static const char *known_dock_uuids[] = {
    "3BDF6A3B-866B-3C07-920C-E9E7FB57B56B",
};

static bool is_known_dock_uuid(const char *uuid) {
  for (size_t i = 0; i < sizeof(known_dock_uuids) / sizeof(known_dock_uuids[0]);
       i++) {
    if (strcmp(uuid, known_dock_uuids[i]) == 0)
      return true;
  }
  return false;
}

// NOTE: Reads LC_UUID from the load commands behind the header. ncmds and each
// cmdsize are checked against sizeofcmds, so a malformed header cannot make the
// loop read past the load commands.
static bool read_image_uuid(const struct mach_header_64 *header,
                            char uuid[sizeof(uuid_string_t)]) {
  if (!header || header->magic != MH_MAGIC_64)
    return false;
  const uint8_t *cursor =
      (const uint8_t *)header + sizeof(struct mach_header_64);
  const uint8_t *end = cursor + header->sizeofcmds;
  for (uint32_t i = 0; i < header->ncmds; i++) {
    size_t remaining = (size_t)(end - cursor);
    if (remaining < sizeof(struct load_command))
      return false;
    const struct load_command *lc = (const struct load_command *)cursor;
    if (lc->cmdsize < sizeof(struct load_command) || lc->cmdsize > remaining)
      return false;
    if (lc->cmd == LC_UUID) {
      if (lc->cmdsize < sizeof(struct uuid_command))
        return false;
      uuid_unparse_upper(((const struct uuid_command *)lc)->uuid, uuid);
      return true;
    }
    cursor += lc->cmdsize;
  }
  return false;
}

static bool verify_os_version(NSOperatingSystemVersion os_version) {
  NSLog(@"[yabai-sa] checking for macOS %ld.%ld.%ld compatibility!",
        os_version.majorVersion, os_version.minorVersion,
        os_version.patchVersion);

  if (sa_os_version_supported(os_version.majorVersion))
    return true;

  NSLog(@"[yabai-sa] spaces functionality is only supported on macOS 27");

  return false;
}

static void init_instances(void) {
  NSOperatingSystemVersion os_version =
      [[NSProcessInfo processInfo] operatingSystemVersion];
  if (!verify_os_version(os_version))
    return;

  const struct mach_header_64 *header =
      (const struct mach_header_64 *)_dyld_get_image_header(0);
  unsigned long text_size = 0;
  const uint8_t *text = getsectiondata(header, "__TEXT", "__text", &text_size);
  if (!text || text_size < 8)
    return;
  uint64_t baseaddr = (uint64_t)header;
  char dock_uuid[sizeof(uuid_string_t)] = "unreadable";
  bool known_dock_build =
      read_image_uuid(header, dock_uuid) && is_known_dock_uuid(dock_uuid);
  text_start = (uint64_t)text;
  text_end = text_start + text_size;
  if (text_end < text_start)
    return;

  dock_spaces = find_instance(baseaddr + get_dock_spaces_offset(),
                              get_dock_spaces_pattern(),
                              @selector(spacesForDisplay:), false);
  dp_desktop_picture_manager =
      find_instance(baseaddr + get_dppm_offset(), get_dppm_pattern(),
                    @selector(moveSpace:toDisplay:displayUUID:), true);
  if (!dock_spaces)
    NSLog(@"[yabai-sa] no validated dock.spaces instance");
  if (!dp_desktop_picture_manager)
    NSLog(@"[yabai-sa] no validated desktop picture manager");

  uint64_t add_space_addr =
      hex_find_seq(baseaddr + get_add_space_offset(), get_add_space_pattern());
  if (add_space_addr == 0x0) {
    NSLog(@"[yabai-sa] failed to get pointer to addSpace function..");
    add_space_fp = 0;
  } else {
    NSLog(@"[yabai-sa] (0x%llx) addSpace found at address 0x%llX (0x%llx)",
          baseaddr, add_space_addr, add_space_addr - baseaddr);
    add_space_fp = (uint64_t)ptrauth_sign_unauthenticated(
        (void *)add_space_addr, ptrauth_key_asia, 0);
  }

  uint64_t remove_space_addr = hex_find_seq(
      baseaddr + get_remove_space_offset(), get_remove_space_pattern());
  if (remove_space_addr == 0x0) {
    NSLog(@"[yabai-sa] failed to get pointer to removeSpace function..");
    remove_space_fp = 0;
  } else {
    NSLog(@"[yabai-sa] (0x%llx) removeSpace found at address 0x%llX (0x%llx)",
          baseaddr, remove_space_addr, remove_space_addr - baseaddr);
    remove_space_fp = (uint64_t)ptrauth_sign_unauthenticated(
        (void *)remove_space_addr, ptrauth_key_asia, 0);
  }

  uint64_t move_space_addr = hex_find_seq(baseaddr + get_move_space_offset(),
                                          get_move_space_pattern());
  if (move_space_addr == 0x0) {
    NSLog(@"[yabai-sa] failed to get pointer to moveSpace function..");
    move_space_fp = 0;
  } else {
    NSLog(@"[yabai-sa] (0x%llx) moveSpace found at address 0x%llX (0x%llx)",
          baseaddr, move_space_addr, move_space_addr - baseaddr);
    move_space_fp = (uint64_t)ptrauth_sign_unauthenticated(
        (void *)move_space_addr, ptrauth_key_asia, 0);
  }

  animation_time_addr = hex_find_seq(baseaddr + get_fix_animation_offset(),
                                     get_fix_animation_pattern());
  if (animation_time_addr == 0x0) {
    NSLog(@"[yabai-sa] failed to get pointer to animation-time..");
  } else {
    NSLog(@"[yabai-sa] (0x%llx) animation_time_addr found at address 0x%llX "
          @"(0x%llx)",
          baseaddr, animation_time_addr, animation_time_addr - baseaddr);
    if (!known_dock_build) {
      NSLog(@"[yabai-sa] unknown Dock build %s; animation patch skipped",
            dock_uuid);
    } else if (vm_protect(mach_task_self(), page_align(animation_time_addr),
                          vm_page_size, 0,
                          VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) ==
               KERN_SUCCESS) {
      *(uint32_t *)animation_time_addr = 0x2f00e400;
      sys_icache_invalidate((void *)animation_time_addr, sizeof(uint32_t));
      animation_time_patched =
          vm_protect(mach_task_self(), page_align(animation_time_addr),
                     vm_page_size, 0,
                     VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS;
      if (!animation_time_patched)
        NSLog(@"[yabai-sa] failed to restore executable animation page "
              @"protection");
    } else {
      NSLog(@"[yabai-sa] animation_time_addr vm_protect failed; unable to "
            @"patch instruction!");
    }
  }
}

static inline id get_ivar_value(id instance, const char *name) {
  id result = nil;
  object_getInstanceVariable(instance, name, (void **)&result);
  return result;
}

//
// NOTE: _currentSpace is a stored property of the Swift class
// DockCore.DisplaySpaces (macOS 27, arm64e). Its class_ro_t has RO_IS_ARC set
// but neither a strong nor a weak ivar layout, so the runtime treats the ivar
// as unretained and object_setInstanceVariable only stores the pointer. The
// field still owns a reference that Swift releases when it overwrites the
// property, so a plain store of a retained value leaked the previous space on
// every write. We write the field directly and retain the new value and release
// the old one ourselves. That is correct for any strong field, Swift or ObjC
// under ARC, and does not depend on how a given macOS version's runtime
// classifies the ivar.
//
static inline void set_current_space(id display_space, id space) {
  if (display_space == nil || space == nil)
    return;

  Ivar ivar = class_getInstanceVariable(object_getClass(display_space),
                                        "_currentSpace");
  if (!ivar)
    return;

  id *location = (id *)((char *)display_space + ivar_getOffset(ivar));
  id old_space = *location;
  if (old_space == space)
    return;

  *location = [space retain];
  [old_space release];
}

static inline uint64_t get_space_id(id space) {
  return ((uint64_t (*)(id, SEL))objc_msgSend)(space, @selector(spid));
}

static inline id space_for_display_with_id(CFStringRef display_uuid,
                                           uint64_t space_id) {
  NSArray *spaces_for_display =
      ((NSArray * (*)(id, SEL, CFStringRef)) objc_msgSend)(
          dock_spaces, @selector(spacesForDisplay:), display_uuid);
  for (id space in spaces_for_display) {
    if (space_id == get_space_id(space)) {
      return space;
    }
  }
  return nil;
}

static inline id display_space_for_display_uuid(CFStringRef display_uuid) {
  id result = nil;

  NSArray *display_spaces = get_ivar_value(dock_spaces, "_displaySpaces");
  if (display_spaces != nil) {
    for (id display_space in display_spaces) {
      id display_source_space = get_ivar_value(display_space, "_currentSpace");
      uint64_t sid = get_space_id(display_source_space);
      CFStringRef uuid =
          SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), sid);
      if (!uuid)
        continue;
      bool match = CFEqual(uuid, display_uuid);
      CFRelease(uuid);
      if (match) {
        result = display_space;
        break;
      }
    }
  }

  return result;
}

static inline id display_space_for_space_with_id(uint64_t space_id) {
  NSArray *display_spaces = get_ivar_value(dock_spaces, "_displaySpaces");
  if (display_spaces != nil) {
    for (id display_space in display_spaces) {
      id display_source_space = get_ivar_value(display_space, "_currentSpace");
      if (get_space_id(display_source_space) == space_id) {
        return display_space;
      }
    }
  }
  return nil;
}

static bool do_space_move(char *message) {
  if (dock_spaces == nil || dp_desktop_picture_manager == nil ||
      move_space_fp == 0)
    return false;

  uint64_t source_space_id, dest_space_id, source_prev_space_id;
  unpack(source_space_id);
  unpack(dest_space_id);
  unpack(source_prev_space_id);

  bool focus_dest_space;
  unpack(focus_dest_space);

  CFStringRef source_display_uuid =
      SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), source_space_id);
  CFStringRef dest_display_uuid =
      SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), dest_space_id);
  if (!source_display_uuid || !dest_display_uuid) {
    if (source_display_uuid)
      CFRelease(source_display_uuid);
    if (dest_display_uuid)
      CFRelease(dest_display_uuid);
    return false;
  }

  __block bool ready = false;
  __block id source_space;
  __block id source_display_space;
  __block id dest_space;
  __block unsigned dest_display_id;
  __block id dest_display_space;

  dispatch_sync(dispatch_get_main_queue(), ^{
    source_space =
        space_for_display_with_id(source_display_uuid, source_space_id);
    source_display_space = display_space_for_display_uuid(source_display_uuid);

    dest_space = space_for_display_with_id(dest_display_uuid, dest_space_id);
    dest_display_space = display_space_for_display_uuid(dest_display_uuid);
    if (!source_space || !dest_space || !source_display_space ||
        !dest_display_space)
      return;
    dest_display_id = ((unsigned (*)(id, SEL, id))objc_msgSend)(
        dock_spaces, @selector(displayIDForSpace:), dest_space);

    if (source_prev_space_id) {
      NSArray *ns_source_space = @[ @(source_space_id) ];
      NSArray *ns_dest_space = @[ @(source_prev_space_id) ];
      id new_source_space =
          space_for_display_with_id(source_display_uuid, source_prev_space_id);
      if (!new_source_space)
        return;
      SLSShowSpaces(SLSMainConnectionID(), (__bridge CFArrayRef)ns_dest_space);
      SLSHideSpaces(SLSMainConnectionID(),
                    (__bridge CFArrayRef)ns_source_space);
      SLSManagedDisplaySetCurrentSpace(
          SLSMainConnectionID(), source_display_uuid, source_prev_space_id);
      set_current_space(source_display_space, new_source_space);
    }
    ready = true;
  });

  if (!ready) {
    CFRelease(source_display_uuid);
    CFRelease(dest_display_uuid);
    return false;
  }
  ((move_space_call)move_space_fp)(source_space, dest_space, dest_display_uuid,
                                   dock_spaces);

  dispatch_sync(dispatch_get_main_queue(), ^{
    ((void (*)(id, SEL, id, unsigned, CFStringRef))objc_msgSend)(
        dp_desktop_picture_manager, @selector(moveSpace:toDisplay:displayUUID:),
        source_space, dest_display_id, dest_display_uuid);

    if (focus_dest_space) {
      uint64_t new_source_space_id = SLSManagedDisplayGetCurrentSpace(
          SLSMainConnectionID(), source_display_uuid);
      id new_source_space =
          space_for_display_with_id(source_display_uuid, new_source_space_id);
      set_current_space(source_display_space, new_source_space);

      NSArray *ns_dest_monitor_space = @[ @(dest_space_id) ];
      SLSHideSpaces(SLSMainConnectionID(),
                    (__bridge CFArrayRef)ns_dest_monitor_space);
      SLSManagedDisplaySetCurrentSpace(SLSMainConnectionID(), dest_display_uuid,
                                       source_space_id);
      set_current_space(dest_display_space, source_space);
    }
  });

  CFRelease(source_display_uuid);
  CFRelease(dest_display_uuid);
  return true;
}

typedef void (*remove_space_call)(id space, id display_space, id dock_spaces,
                                  uint64_t space_id1, uint64_t space_id2);
static bool do_space_destroy(char *message) {
  if (dock_spaces == nil || remove_space_fp == 0)
    return false;

  uint64_t space_id;
  unpack(space_id);

  CFStringRef display_uuid =
      SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), space_id);
  if (!display_uuid)
    return false;
  uint64_t active_space_id =
      SLSManagedDisplayGetCurrentSpace(SLSMainConnectionID(), display_uuid);

  __block bool accepted = false;
  dispatch_sync(dispatch_get_main_queue(), ^{
    id space = space_for_display_with_id(display_uuid, space_id);
    id display_space = display_space_for_display_uuid(display_uuid);
    if (!space || !display_space)
      return;

    ((remove_space_call)remove_space_fp)(space, display_space, dock_spaces,
                                         space_id, space_id);
    accepted = true;

    if (active_space_id == space_id) {
      uint64_t dest_space_id =
          SLSManagedDisplayGetCurrentSpace(SLSMainConnectionID(), display_uuid);
      id dest_space = space_for_display_with_id(display_uuid, dest_space_id);
      set_current_space(display_space, dest_space);
    }
  });

  CFRelease(display_uuid);
  return accepted;
}

static bool do_space_create(char *message) {
  if (dock_spaces == nil || add_space_fp == 0)
    return false;

  uint64_t space_id;
  unpack(space_id);

  CFStringRef __block display_uuid =
      SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), space_id);
  if (!display_uuid)
    return false;
  __block bool accepted = false;
  dispatch_sync(dispatch_get_main_queue(), ^{
    id new_space = [[objc_getClass("ManagedSpace") alloc] init];
    id display_space = display_space_for_display_uuid(display_uuid);
    // NOTE: On Dock 26A434 addSpace borrows x0, retaining separately for its
    // space array. Dock's own caller passes a borrowed object. Balance our
    // alloc/init reference here.
    @try {
      if (new_space && display_space) {
        ((add_space_call)add_space_fp)(new_space, display_space);
        accepted = true;
      }
    } @finally {
      [new_space release];
    }
  });
  CFRelease(display_uuid);
  return accepted;
}

static bool do_space_focus(char *message) {
  if (dock_spaces == nil)
    return false;

  uint64_t dest_space_id;
  unpack(dest_space_id);

  __block bool accepted = false;
  if (dest_space_id) {
    CFStringRef dest_display =
        SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), dest_space_id);
    if (!dest_display)
      return false;

    dispatch_sync(dispatch_get_main_queue(), ^{
      id source_space = ((id (*)(id, SEL, CFStringRef))objc_msgSend)(
          dock_spaces, @selector(currentSpaceForDisplayUUID:), dest_display);
      uint64_t source_space_id = get_space_id(source_space);
      if (source_space_id == dest_space_id) {
        accepted = true;
        return;
      }

      id dest_space = space_for_display_with_id(dest_display, dest_space_id);
      if (dest_space == nil)
        return;

      id display_space = display_space_for_space_with_id(source_space_id);
      if (display_space == nil)
        return;

      NSArray *ns_source_space = @[ @(source_space_id) ];
      NSArray *ns_dest_space = @[ @(dest_space_id) ];
      SLSShowSpaces(SLSMainConnectionID(), (__bridge CFArrayRef)ns_dest_space);
      SLSHideSpaces(SLSMainConnectionID(),
                    (__bridge CFArrayRef)ns_source_space);
      SLSManagedDisplaySetCurrentSpace(SLSMainConnectionID(), dest_display,
                                       dest_space_id);
      set_current_space(display_space, dest_space);
      accepted = true;
    });

    CFRelease(dest_display);
  }
  return accepted;
}

static bool do_window_scale(char *message) {
  uint32_t wid;
  unpack(wid);
  if (!wid)
    return true;

  CGRect frame = {};
  if (SLSGetWindowBounds(SLSMainConnectionID(), wid, &frame) != kCGErrorSuccess)
    return false;
  CGAffineTransform original_transform =
      CGAffineTransformMakeTranslation(-frame.origin.x, -frame.origin.y);

  CGAffineTransform current_transform;
  if (SLSGetWindowTransform(SLSMainConnectionID(), wid, &current_transform) !=
      kCGErrorSuccess)
    return false;

  if (CGAffineTransformEqualToTransform(current_transform,
                                        original_transform)) {
    float dx, dy, dw, dh;
    unpack(dx);
    unpack(dy);
    unpack(dw);
    unpack(dh);

    if (dw <= 0 || dh <= 0 || frame.size.width <= 0 || frame.size.height <= 0)
      return false;
    if ((double)dw / 4 > INT_MAX)
      return false;
    int target_width = dw / 4;
    if ((double)target_width / (frame.size.width / frame.size.height) > INT_MAX)
      return false;
    int target_height = target_width / (frame.size.width / frame.size.height);
    if (target_width <= 0 || target_height <= 0)
      return false;

    float x_scale = frame.size.width / target_width;
    float y_scale = frame.size.height / target_height;

    CGFloat transformed_x = -(dx + dw) + (frame.size.width * (1 / x_scale));
    CGFloat transformed_y = -dy;

    CGAffineTransform scale =
        CGAffineTransformConcat(CGAffineTransformIdentity,
                                CGAffineTransformMakeScale(x_scale, y_scale));
    CGAffineTransform transform =
        CGAffineTransformTranslate(scale, transformed_x, transformed_y);
    return SLSSetWindowTransform(SLSMainConnectionID(), wid, transform) ==
           kCGErrorSuccess;
  } else {
    return SLSSetWindowTransform(SLSMainConnectionID(), wid,
                                 original_transform) == kCGErrorSuccess;
  }
}

static bool do_window_move(char *message) {
  uint32_t wid;
  unpack(wid);
  if (!wid)
    return true;

  int x, y;
  unpack(x);
  unpack(y);

  CGPoint point = CGPointMake(x, y);
  OSStatus status = SLSMoveWindowWithGroup(SLSMainConnectionID(), wid, &point);

  NSArray *window_list = @[ @(wid) ];
  CGError associated = SLSReassociateWindowsSpacesByGeometry(
      SLSMainConnectionID(), (__bridge CFArrayRef)window_list);
  return status == noErr && associated == kCGErrorSuccess;
}

static bool do_window_layer(char *message) {
  uint32_t wid;
  unpack(wid);
  if (!wid)
    return true;

  int layer;
  unpack(layer);

  return SLSSetWindowSubLevel(SLSMainConnectionID(), wid,
                              CGWindowLevelForKey(layer)) == kCGErrorSuccess;
}

static bool do_window_sticky(char *message) {
  uint32_t wid;
  unpack(wid);
  if (!wid)
    return true;

  bool value;
  unpack(value);

  uint64_t tags = (1 << 11);
  if (value == 1) {
    return SLSSetWindowTags(SLSMainConnectionID(), wid, &tags, 64) ==
           kCGErrorSuccess;
  } else {
    return SLSClearWindowTags(SLSMainConnectionID(), wid, &tags, 64) ==
           kCGErrorSuccess;
  }
}

static bool do_window_shadow(char *message) {
  uint32_t wid;
  unpack(wid);
  if (!wid)
    return true;

  bool value;
  unpack(value);

  uint64_t tags = (1 << 3);
  if (value == 1) {
    return SLSClearWindowTags(SLSMainConnectionID(), wid, &tags, 64) ==
           kCGErrorSuccess;
  } else {
    return SLSSetWindowTags(SLSMainConnectionID(), wid, &tags, 64) ==
           kCGErrorSuccess;
  }
}

//
// NOTE: The entries are ordered one after another, each with its own
// SLSOrderWindow call. A transaction would not do: its ordering
// does not follow the sequence, and the order of the windows of a tabbed
// container depends on it.
//

static bool do_window_order_list(char *message, int length) {
  int count = 0;
  unpack(count);

  int entry_size = 2 * sizeof(uint32_t) + sizeof(int);
  int max_count = (length - (int)sizeof(int)) / entry_size;
  if (count > max_count)
    count = max_count;

  bool success = true;
  for (int i = 0; i < count; ++i) {
    uint32_t a_wid;
    unpack(a_wid);

    int order;
    unpack(order);

    uint32_t b_wid;
    unpack(b_wid);

    if (a_wid && SLSOrderWindow(SLSMainConnectionID(), a_wid, order, b_wid) !=
                     kCGErrorSuccess)
      success = false;
  }
  return success;
}

static bool do_window_order_in(char *message) {
  int count = 0;
  unpack(count);
  if (!count)
    return true;

  CFTypeRef transaction = SLSTransactionCreate(SLSMainConnectionID());
  if (!transaction)
    return false;
  bool success = true;
  for (int i = 0; i < count; ++i) {
    uint32_t wid;
    unpack(wid);
    if (!wid)
      continue;

    if (SLSTransactionOrderWindowGroup(transaction, wid, 1, 0) !=
        kCGErrorSuccess)
      success = false;
  }
  if (SLSTransactionCommit(transaction, 0) != kCGErrorSuccess)
    success = false;
  CFRelease(transaction);
  return success;
}

static CFArrayRef create_window_list(const void *values,
                                     int count) CF_RETURNS_RETAINED;
static CFArrayRef create_window_list(const void *values, int count) {
  CFMutableArrayRef result =
      CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
  if (!result)
    return NULL;
  for (int i = 0; i < count; ++i) {
    // Wire fields are not naturally aligned. CFNumberCreate must get typed,
    // aligned storage.
    int32_t wid;
    memcpy(&wid, (const char *)values + sizeof(wid) * (size_t)i, sizeof(wid));
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &wid);
    if (!number) {
      CFRelease(result);
      return NULL;
    }
    CFArrayAppendValue(result, number);
    CFRelease(number);
  }
  return result;
}

static bool do_window_list_move_to_space(char *message) {
  uint64_t sid;
  unpack(sid);

  int count = 0;
  unpack(count);

  CFArrayRef window_list_ref = create_window_list(message, count);
  if (!window_list_ref)
    return false;
  SLSMoveWindowsToManagedSpace(SLSMainConnectionID(), window_list_ref, sid);
  CFRelease(window_list_ref);
  return true;
}

uint32_t sa_native_attributes(void) {
  uint32_t attributes = 0;
  if (dock_spaces)
    attributes |= OSAX_ATTRIB_DOCK_SPACES;
  if (dp_desktop_picture_manager)
    attributes |= OSAX_ATTRIB_DPPM;
  if (add_space_fp)
    attributes |= OSAX_ATTRIB_ADD_SPACE;
  if (remove_space_fp)
    attributes |= OSAX_ATTRIB_REM_SPACE;
  if (move_space_fp)
    attributes |= OSAX_ATTRIB_MOV_SPACE;
  if (animation_time_patched)
    attributes |= OSAX_ATTRIB_ANIM_TIME;
  return attributes;
}

const char *sa_native_version(void) { return OSAX_VERSION; }

uint8_t sa_native_dispatch(const uint8_t *bytes, size_t length) {
  if (!bytes || !length)
    return SA_REPLY_INVALID;
  uint8_t opcode = bytes[0];
  char *message = (char *)bytes + 1;
  uint32_t required = 0;
  switch (opcode) {
  case SA_OPCODE_SPACE_FOCUS:
    required = OSAX_ATTRIB_DOCK_SPACES;
    break;
  case SA_OPCODE_SPACE_CREATE:
    required = OSAX_ATTRIB_DOCK_SPACES | OSAX_ATTRIB_ADD_SPACE;
    break;
  case SA_OPCODE_SPACE_DESTROY:
    required = OSAX_ATTRIB_DOCK_SPACES | OSAX_ATTRIB_REM_SPACE;
    break;
  case SA_OPCODE_SPACE_MOVE:
    required =
        OSAX_ATTRIB_DOCK_SPACES | OSAX_ATTRIB_DPPM | OSAX_ATTRIB_MOV_SPACE;
    break;
  default:
    break;
  }
  if ((sa_native_attributes() & required) != required)
    return SA_REPLY_UNSUPPORTED;
  @try {
    switch (opcode) {
    case SA_OPCODE_SPACE_FOCUS:
      return do_space_focus(message) ? SA_REPLY_ACCEPTED : SA_REPLY_FAILED;
    case SA_OPCODE_SPACE_CREATE:
      return do_space_create(message) ? SA_REPLY_ACCEPTED : SA_REPLY_FAILED;
    case SA_OPCODE_SPACE_DESTROY:
      return do_space_destroy(message) ? SA_REPLY_ACCEPTED : SA_REPLY_FAILED;
    case SA_OPCODE_SPACE_MOVE:
      return do_space_move(message) ? SA_REPLY_ACCEPTED : SA_REPLY_FAILED;
    case SA_OPCODE_WINDOW_MOVE:
      return do_window_move(message) ? SA_REPLY_ACCEPTED : SA_REPLY_FAILED;
    case SA_OPCODE_WINDOW_LAYER:
      return do_window_layer(message) ? SA_REPLY_ACCEPTED : SA_REPLY_FAILED;
    case SA_OPCODE_WINDOW_STICKY:
      return do_window_sticky(message) ? SA_REPLY_ACCEPTED : SA_REPLY_FAILED;
    case SA_OPCODE_WINDOW_SHADOW:
      return do_window_shadow(message) ? SA_REPLY_ACCEPTED : SA_REPLY_FAILED;
    case SA_OPCODE_WINDOW_SCALE:
      return do_window_scale(message) ? SA_REPLY_ACCEPTED : SA_REPLY_FAILED;
    case SA_OPCODE_WINDOW_ORDER_LIST:
      return do_window_order_list(message, (int)length - 1) ? SA_REPLY_ACCEPTED
                                                            : SA_REPLY_FAILED;
    case SA_OPCODE_WINDOW_ORDER_IN:
      return do_window_order_in(message) ? SA_REPLY_ACCEPTED : SA_REPLY_FAILED;
    case SA_OPCODE_WINDOW_LIST_TO_SPACE:
      return do_window_list_move_to_space(message) ? SA_REPLY_ACCEPTED
                                                   : SA_REPLY_FAILED;
    default:
      return SA_REPLY_UNSUPPORTED;
    }
  } @catch (NSException *exception) {
    NSLog(@"[yabai-sa] command %u failed: %@", opcode, exception.reason);
    return SA_REPLY_FAILED;
  }
  return SA_REPLY_ACCEPTED;
}

static void *handle_connection(void *unused) {
  (void)unused;
  for (;;) {
    int sockfd = accept(daemon_sockfd, NULL, NULL);
    if (sockfd == -1) {
      if (errno == EINTR)
        continue;
      usleep(10000);
      continue;
    }
    uid_t peer;
    gid_t group;
    if (getpeereid(sockfd, &peer, &group) != 0 ||
        (peer != getuid() && peer != 0)) {
      close(sockfd);
      continue;
    }
    @autoreleasepool {
      // Each core owns framing, validation and response handling. Native calls
      // are made only after validation, and no socket read can indefinitely
      // monopolize this serial server.
      sa_core_serve(sockfd);
    }
    shutdown(sockfd, SHUT_RDWR);
    close(sockfd);
  }
  return NULL;
}

static bool start_daemon(char *socket_path) {
  struct sockaddr_un address = {.sun_family = AF_UNIX};
  if (strlen(socket_path) >= sizeof(address.sun_path))
    return false;
  memcpy(address.sun_path, socket_path, strlen(socket_path) + 1);
  struct stat existing;
  if (lstat(socket_path, &existing) == 0) {
    if (!S_ISSOCK(existing.st_mode) || existing.st_uid != getuid())
      return false;
    if (unlink(socket_path) != 0)
      return false;
  } else if (errno != ENOENT) {
    return false;
  }
  daemon_sockfd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (daemon_sockfd == -1)
    return false;
  if (bind(daemon_sockfd, (struct sockaddr *)&address, sizeof(address)) != 0)
    goto fail;
  if (chmod(socket_path, 0600) != 0 || listen(daemon_sockfd, SOMAXCONN) != 0)
    goto unlink_socket;

  init_instances();
  pthread_t daemon_thread;
  if (pthread_create(&daemon_thread, NULL, handle_connection, NULL) != 0)
    goto unlink_socket;
  pthread_detach(daemon_thread);
  return true;

unlink_socket:
  unlink(socket_path);
fail:
  close(daemon_sockfd);
  return false;
}

__attribute__((constructor)) void load_payload(void) {
  @autoreleasepool {
    NSLog(@"[yabai-sa] loaded payload %s", OSAX_VERSION);
    struct passwd *user = getpwuid(getuid());
    if (!user) {
      NSLog(@"[yabai-sa] cannot resolve user");
      return;
    }
    char socket_file[sizeof(((struct sockaddr_un *)0)->sun_path)];
    int length = snprintf(socket_file, sizeof(socket_file), SA_SOCKET_PATH_FMT,
                          user->pw_name);
    if (length < 0 || (size_t)length >= sizeof(socket_file))
      return;
    NSLog(@"[yabai-sa] %@", start_daemon(socket_file)
                                ? @"now listening"
                                : @"failed to initialize server");
  }
}

//
// NOTE: addSpace and moveSpace are Swift methods of Dock: self (the display
// space, or dock.spaces) goes in x20. swift_context lowers to LLVM swiftself,
// which is x20 on arm64, so the compiler sets every argument register right
// before the call. Setting x20 in inline asm and calling in a separate
// statement left the compiler free to reuse those registers in between.
//
typedef void (*add_space_call)(id space,
                               id display_space __attribute__((swift_context)))
    __attribute__((swiftcall));
typedef void (*move_space_call)(id source_space, id dest_space,
                                CFStringRef dest_display_uuid,
                                id dock_spaces __attribute__((swift_context)))
    __attribute__((swiftcall));

// NOTE: From 27.2 the move_space lookup is the Dock's handler for a space move
// that WindowManager.app reports, not the mover above. Its arguments are those
// of SpaceChange.movedToDisplay: the space, the display UUID as a Swift String
// and the space to insert after as an optional id. It returns whether the Dock
// applied the change.
struct swift_string {
  uint64_t bits;
  void *object;
};
typedef struct swift_string (*swift_string_create_call)(const char *cstring)
    __attribute__((swiftcall));
typedef void (*swift_bridge_object_release_call)(void *object);
typedef uint64_t (*space_moved_call)(
    uint64_t space_id, uint64_t display_uuid_bits, void *display_uuid_object,
    uint64_t after_space_id, uint8_t after_space_is_nil,
    id dock_spaces __attribute__((swift_context))) __attribute__((swiftcall));

// NOTE: From macOS 27.2 (26B123) the Dock is a fat binary with an arm64e and
// an arm64e.x1 slice. The x1 slice opens functions with pacibsppc
// (FE A7 C1 DA) instead of pacibsp (7F 23 03 D5), so the 27.2 function
// patterns wildcard the first instruction. The 27.0 values were validated on
// 26A434 and stay as they were. See doc/osax-prototypes.md "Dock inspection".
static bool is_macos_27_2_or_later(void) {
  NSOperatingSystemVersion version =
      [[NSProcessInfo processInfo] operatingSystemVersion];
  return version.majorVersion > 27 ||
         (version.majorVersion == 27 && version.minorVersion >= 2);
}

uint64_t get_dock_spaces_offset(void) {
  return is_macos_27_2_or_later() ? 0x20000 : 0x30000;
}

uint64_t get_dppm_offset(void) { return 0x40000; }

uint64_t get_fix_animation_offset(void) {
  return is_macos_27_2_or_later() ? 0x160000 : 0x200000;
}

uint64_t get_add_space_offset(void) {
  return is_macos_27_2_or_later() ? 0x160000 : 0x200000;
}

uint64_t get_remove_space_offset(void) {
  return is_macos_27_2_or_later() ? 0x120000 : 0x150000;
}

uint64_t get_move_space_offset(void) {
  return is_macos_27_2_or_later() ? 0x100000 : 0x150000;
}

const char *get_dock_spaces_pattern(void) {
  // Pulling out of doBindingCommand:display (search decompiled text in ghidra)
  // function.
  return "?8 ?? ?? ?? 08 ?? ?? 91 00 01 40 F9 E2 03 13 AA ?? ?? ?? 94 ?? ?? ?? "
         "?? 08";
}

const char *get_dppm_pattern(void) {
  // Pulling from function 'DPRemoteConnection::_handleEvent:'
  // NOTE: DPDesktopPictureManager no longer exists on 27.2; its successor
  // (DockCore.WallpaperAgentDesktopPictureManager) has no
  // moveSpace:toDisplay:displayUUID:, so this finds nothing there.
  return "?? ?? 00 ?? 08 ?? ?? 91 00 01 40 F9 E2 03 16 AA E3 03 19 AA ?? ?? ?? "
         "94";
}

const char *get_fix_animation_pattern(void) {
  return "00 10 6A 1E A8 ?? ?? D1 ?? 01 ?? F8";
}

const char *get_add_space_pattern(void) {
  if (is_macos_27_2_or_later())
    return "?? ?? ?? ?? E1 03 1E AA ?? ?? ?? 97 FE 03 01 AA FD 7B 05 A9 FD 43 "
           "01 91 F3 03 14 AA F5 03";
  return "7F 23 03 D5 E1 03 1E AA ?? ?? ?? 97 FE 03 01 AA FD 7B 05 A9 FD 43 01 "
         "91 F3 03 14 AA F5 03";
}

const char *get_remove_space_pattern(void) {
  if (is_macos_27_2_or_later())
    return "?? ?? ?? ?? FF ?? ?? D1 FC ?? ?? A9 FA ?? ?? A9 F8 ?? ?? A9 F6 ?? "
           "?? A9 F4 ?? ?? A9 FD ?? ?? A9 FD ?? ?? 91 ?? 03 03 AA F5 03 02 AA "
           "F4 03 01 AA";
  return "7F 23 03 D5 FF ?? ?? D1 FC ?? ?? A9 FA ?? ?? A9 F8 ?? ?? A9 F6 ?? ?? "
         "A9 F4 ?? ?? A9 FD ?? ?? A9 FD ?? ?? 91 ?? 03 03 AA F5 03 02 AA F4 03 "
         "01 AA";
}

const char *get_move_space_pattern(void) {
  if (is_macos_27_2_or_later())
    return "?? ?? ?? ?? E5 03 1E AA ?? ?? ?? 97 FE 03 05 AA FD 7B ?? A9 FD ?? "
           "?? 91 F6 03 14 AA F7 03 04 AA F4 03 03 AA F8 03 02 AA F9 03 01 AA "
           "E1 03 16 AA";
  return "7F 23 03 D5 E3 03 1E AA ?? ?? ?? 97 FE 03 03 AA FD 7B ?? A9 FD ?? ?? "
         "91 F6 03 14 AA";
}

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

uint64_t get_dock_spaces_offset(void) { return 0x30000; }

uint64_t get_dppm_offset(void) { return 0x40000; }

uint64_t get_fix_animation_offset(void) { return 0x200000; }

uint64_t get_add_space_offset(void) { return 0x200000; }

uint64_t get_remove_space_offset(void) { return 0x150000; }

uint64_t get_move_space_offset(void) { return 0x150000; }

const char *get_dock_spaces_pattern(void) {
  // Pulling out of doBindingCommand:display (search decompiled text in ghidra)
  // function.
  return "?8 ?? ?? ?? 08 ?? ?? 91 00 01 40 F9 E2 03 13 AA ?? ?? ?? 94 ?? ?? ?? "
         "?? 08";
}

const char *get_dppm_pattern(void) {
  // Pulling from function 'DPRemoteConnection::_handleEvent:'
  return "?? ?? 00 ?? 08 ?? ?? 91 00 01 40 F9 E2 03 16 AA E3 03 19 AA ?? ?? ?? "
         "94";
}

const char *get_fix_animation_pattern(void) {
  return "00 10 6A 1E A8 ?? ?? D1 ?? 01 ?? F8";
}

const char *get_add_space_pattern(void) {
  return "7F 23 03 D5 E1 03 1E AA ?? ?? ?? 97 FE 03 01 AA FD 7B 05 A9 FD 43 01 "
         "91 F3 03 14 AA F5 03";
}

const char *get_remove_space_pattern(void) {
  return "7F 23 03 D5 FF ?? ?? D1 FC ?? ?? A9 FA ?? ?? A9 F8 ?? ?? A9 F6 ?? ?? "
         "A9 F4 ?? ?? A9 FD ?? ?? A9 FD ?? ?? 91 ?? 03 03 AA F5 03 02 AA F4 03 "
         "01 AA";
}

const char *get_move_space_pattern(void) {
  return "7F 23 03 D5 E3 03 1E AA ?? ?? ?? 97 FE 03 03 AA FD 7B ?? A9 FD ?? ?? "
         "91 F6 03 14 AA";
}

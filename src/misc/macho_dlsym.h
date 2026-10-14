#ifndef MACHO_DLSYM_H
#define MACHO_DLSYM_H

// implemented in Sources/Yabai/Platform/MachO.swift
void *macho_find_symbol(char *target_image, char *target_symbol);

#endif

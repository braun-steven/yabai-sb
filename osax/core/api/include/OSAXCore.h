#ifndef OSAX_CORE_H
#define OSAX_CORE_H

#include "../../../common.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Native adapter. The Swift core validates the complete message before calling
// dispatch. No native pointer, Objective-C object, private calling convention
// or code patch crosses this interface.
uint8_t sa_native_dispatch(const uint8_t *message, size_t length);
uint32_t sa_native_attributes(void);
const char *sa_native_version(void);
// The LC_UUID of the Dock image, empty when unreadable, and whether the payload
// validated that build (known_dock_uuids in payload.m).
const char *sa_native_dock_uuid(void);
bool sa_native_dock_known(void);
size_t sa_pattern_scan(const uint8_t *bytes, size_t length, const char *pattern,
                       size_t *offsets, size_t capacity);
bool sa_pattern_find_unique_aligned(const uint8_t *bytes, size_t length,
                                    const char *pattern, uintptr_t base,
                                    size_t *offset, size_t *match_count);
bool sa_os_version_supported(int64_t major_version);
bool sa_decode_adrp_add(uint32_t adrp, uint32_t add, uint64_t pc,
                        uint64_t *target);

bool sa_swift_validate(const uint8_t *message, size_t length);
bool sa_swift_serve(int fd);

#ifndef __swift__
#define sa_core_serve sa_swift_serve
#endif

#endif

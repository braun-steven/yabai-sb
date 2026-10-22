#ifndef OSAX_CORE_H
#define OSAX_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "../../../common.h"

// Native adapter. The Swift core validates the complete message before calling dispatch. No native
// pointer, Objective-C object, private calling convention or code patch crosses this interface.
uint8_t sa_native_dispatch(const uint8_t *message, size_t length);
uint32_t sa_native_attributes(void);
const char *sa_native_version(void);
bool sa_native_get_alpha(uint32_t wid, float *alpha);
bool sa_native_set_alpha(uint32_t wid, float alpha);
uint64_t sa_clock_ns(void);
size_t sa_pattern_scan(const uint8_t *bytes, size_t length, const char *pattern, size_t *offsets, size_t capacity);
bool sa_decode_adrp_add(uint32_t adrp, uint32_t add, uint64_t pc, uint64_t *target);

bool sa_swift_validate(const uint8_t *message, size_t length);
bool sa_swift_serve(int fd);
bool sa_swift_opacity(uint32_t wid, float alpha, float duration, uint64_t now);
bool sa_swift_tick(uint64_t now);
bool sa_swift_has_fades(void);
void sa_swift_reset(void);

#ifndef __swift__
#define sa_core_serve sa_swift_serve
#define sa_core_opacity sa_swift_opacity
#define sa_core_tick sa_swift_tick
#define sa_core_has_fades sa_swift_has_fades
#endif

#endif

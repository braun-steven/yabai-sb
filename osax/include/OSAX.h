#ifndef OSAX_H
#define OSAX_H

//
// NOTE: The scripting addition as the daemon sees it: the opcodes and attributes of the payload (common.h, which
// payload.m includes too) and the payload and loader binaries, which OSAXEmbed builds and xxd turns into C byte arrays
// in the plugin work directory. Swift imports this header as the module OSAX.
//

#include "../common.h"

const char *sa_payload_version(void);

extern unsigned char __osax_payload[];
extern unsigned int __osax_payload_len;
extern unsigned char __osax_loader[];
extern unsigned int __osax_loader_len;

static inline unsigned char *sa_loader_bytes(void) { return __osax_loader; }
static inline unsigned int sa_loader_size(void) { return __osax_loader_len; }
static inline unsigned char *sa_payload_bytes(void) { return __osax_payload; }
static inline unsigned int sa_payload_size(void) { return __osax_payload_len; }

#endif

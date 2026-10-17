#include <Foundation/Foundation.h>
#include <math.h>
#include <pthread.h>
#include "../api/include/OSAXCore.h"
#include "IO.h"

static bool take(const uint8_t **cursor, size_t *remaining, void *value, size_t size)
{
    if (*remaining < size) return false;
    memcpy(value, *cursor, size);
    *cursor += size;
    *remaining -= size;
    return true;
}

bool sa_objc_validate(const uint8_t *message, size_t length)
{
    if (!message || length < 1 || length > SA_SOCKET_BUFF_LEN - 2) return false;
    uint8_t opcode = *message++;
    --length;
    size_t expected;
    switch (opcode) {
    case SA_OPCODE_HANDSHAKE: expected = 0; break;
    case SA_OPCODE_SPACE_FOCUS:
    case SA_OPCODE_SPACE_CREATE:
    case SA_OPCODE_SPACE_DESTROY: expected = 8; break;
    case SA_OPCODE_SPACE_MOVE: expected = 25; break;
    case SA_OPCODE_WINDOW_MOVE:
    case SA_OPCODE_WINDOW_OPACITY_FADE:
    case SA_OPCODE_WINDOW_ORDER:
    case SA_OPCODE_WINDOW_TO_SPACE: expected = 12; break;
    // The client historically sends a duration for both opacity commands.
    case SA_OPCODE_WINDOW_OPACITY: expected = 12; break;
    case SA_OPCODE_WINDOW_LAYER: expected = 8; break;
    case SA_OPCODE_WINDOW_STICKY:
    case SA_OPCODE_WINDOW_SHADOW: expected = 5; break;
    case SA_OPCODE_WINDOW_FOCUS: expected = 4; break;
    case SA_OPCODE_WINDOW_SCALE: expected = 20; break;
    case SA_OPCODE_WINDOW_SWAP_PROXY_IN:
    case SA_OPCODE_WINDOW_SWAP_PROXY_OUT:
    case SA_OPCODE_WINDOW_ORDER_IN:
    case SA_OPCODE_WINDOW_LIST_TO_SPACE:
    case SA_OPCODE_WINDOW_ORDER_LIST: {
        if (opcode == SA_OPCODE_WINDOW_LIST_TO_SPACE) {
            uint64_t sid;
            if (!take(&message, &length, &sid, sizeof(sid))) return false;
        }
        int32_t count;
        if (!take(&message, &length, &count, sizeof(count)) || count < 0) return false;
        if (opcode == SA_OPCODE_WINDOW_SWAP_PROXY_IN || opcode == SA_OPCODE_WINDOW_SWAP_PROXY_OUT) {
            // A skipped animation has just a zero wid, not a fixed-width pair.
            if ((size_t)count > length / 4) return false;
            for (int32_t i = 0; i < count; ++i) {
                uint32_t wid, proxy;
                if (!take(&message, &length, &wid, sizeof(wid))) return false;
                if (wid && !take(&message, &length, &proxy, sizeof(proxy))) return false;
            }
            return length == 0;
        }
        size_t width = opcode == SA_OPCODE_WINDOW_ORDER_LIST ? 12 : 4;
        return length % width == 0 && (size_t)count == length / width;
    }
    default: return false;
    }
    if (length != expected) return false;
    if (opcode == SA_OPCODE_SPACE_MOVE && message[24] > 1) return false;
    if ((opcode == SA_OPCODE_WINDOW_STICKY || opcode == SA_OPCODE_WINDOW_SHADOW) && message[4] > 1) return false;
    if (opcode == SA_OPCODE_WINDOW_OPACITY || opcode == SA_OPCODE_WINDOW_OPACITY_FADE) {
        float alpha, duration;
        memcpy(&alpha, message + 4, 4);
        memcpy(&duration, message + 8, 4);
        if (!isfinite(alpha) || alpha < 0 || alpha > 1 || !isfinite(duration) || duration < 0) return false;
    }
    if (opcode == SA_OPCODE_WINDOW_SCALE) {
        for (size_t i = 4; i < 20; i += 4) {
            float value;
            memcpy(&value, message + i, 4);
            if (!isfinite(value)) return false;
        }
    }
    return true;
}

bool sa_objc_serve(int fd)
{
    if (!sa_io_prepare(fd)) return false;
    uint64_t deadline = sa_io_now() + (uint64_t)SA_READ_TIMEOUT_MS * 1000000;
    uint16_t length;
    uint8_t message[SA_SOCKET_BUFF_LEN];
    if (!sa_io_transfer(fd, &length, sizeof(length), false, deadline)) return false;
    uint8_t reply = SA_REPLY_INVALID;
    if (length > 0 && length <= SA_SOCKET_BUFF_LEN - 2 && sa_io_transfer(fd, message, length, false, deadline)
        && sa_objc_validate(message, length)) {
        if (message[0] == SA_OPCODE_HANDSHAKE) {
            const char *version = sa_native_version();
            size_t size = strlen(version) + 1;
            uint8_t response[256];
            if (size + 5 > sizeof(response)) return false;
            memcpy(response, version, size);
            uint32_t attributes = sa_native_attributes();
            memcpy(response + size, &attributes, sizeof(attributes));
            response[size + 4] = '\n';
            return sa_io_transfer(fd, response, size + 5, true, sa_io_now() + 1000000000);
        }
        reply = sa_native_dispatch(message, length);
    }
    return sa_io_transfer(fd, &reply, 1, true, sa_io_now() + 1000000000);
}

@interface SAFade : NSObject
@property uint32_t wid;
@property float startAlpha;
@property float alpha;
@property float duration;
@property uint64_t start;
@end
@implementation SAFade
@end

// NOTE: The mutex also serializes native alpha reads/writes with replacement and cancellation.
// A tick cannot apply an obsolete fade after a newer immediate opacity command.
static pthread_mutex_t fade_lock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary *fades;

bool sa_objc_opacity(uint32_t wid, float alpha, float duration, uint64_t now)
{
    if (!wid || !isfinite(alpha) || alpha < 0 || alpha > 1 || !isfinite(duration) || duration < 0) return false;
    pthread_mutex_lock(&fade_lock);
    if (!fades) fades = [[NSMutableDictionary alloc] init];
    NSNumber *key = @(wid);
    [fades removeObjectForKey:key];
    bool result;
    if (duration == 0) {
        result = sa_native_set_alpha(wid, alpha);
    } else {
        float start;
        result = sa_native_get_alpha(wid, &start);
        if (result) {
            SAFade *fade = [[SAFade alloc] init];
            fade.wid = wid;
            fade.startAlpha = start;
            fade.alpha = alpha;
            fade.duration = duration;
            fade.start = now;
            fades[key] = fade;
            [fade release];
        }
    }
    pthread_mutex_unlock(&fade_lock);
    return result;
}

void sa_objc_tick(uint64_t now)
{
    @autoreleasepool {
        pthread_mutex_lock(&fade_lock);
        NSArray *keys = [fades allKeys];
        for (NSNumber *key in keys) {
            SAFade *fade = fades[key];
            double elapsed = now >= fade.start ? (double)(now - fade.start) / 1e9 : 0;
            double t = fmin(1, elapsed / fade.duration);
            float alpha = (float)((1 - t) * fade.startAlpha + t * fade.alpha);
            if (!sa_native_set_alpha(fade.wid, alpha) || t >= 1) [fades removeObjectForKey:key];
        }
        pthread_mutex_unlock(&fade_lock);
    }
}

void sa_objc_reset(void)
{
    pthread_mutex_lock(&fade_lock);
    [fades removeAllObjects];
    pthread_mutex_unlock(&fade_lock);
}

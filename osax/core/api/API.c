// SwiftPM needs a source for the declarations imported by the payload and its isolated tests.
#include "include/OSAXCore.h"
#include <string.h>

static int nibble(char value)
{
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    return -1;
}

size_t sa_pattern_scan(const uint8_t *bytes, size_t length, const char *pattern, size_t *offsets, size_t capacity)
{
    uint8_t values[128], masks[128];
    size_t count = 0;
    if (!bytes || !pattern || (capacity && !offsets)) return 0;
    size_t size = strlen(pattern);
    if (!size || (size + 1) % 3 != 0 || (size + 1) / 3 > sizeof(values)) return 0;
    for (size_t i = 0; i < size; i += 3) {
        if (i + 2 < size && pattern[i + 2] != ' ') return 0;
        int high = nibble(pattern[i]), low = nibble(pattern[i + 1]);
        if ((high < 0 && pattern[i] != '?') || (low < 0 && pattern[i + 1] != '?')) return 0;
        values[count] = (uint8_t)((high < 0 ? 0 : high << 4) | (low < 0 ? 0 : low));
        masks[count++] = (uint8_t)((high < 0 ? 0 : 0xf0) | (low < 0 ? 0 : 0x0f));
    }
    if (length < count) return 0;
    size_t found = 0;
    for (size_t offset = 0; offset <= length - count; ++offset) {
        size_t i = 0;
        while (i < count && (bytes[offset + i] & masks[i]) == values[i]) ++i;
        if (i == count) {
            if (found < capacity) offsets[found] = offset;
            ++found;
        }
    }
    return found;
}

bool sa_decode_adrp_add(uint32_t adrp, uint32_t add, uint64_t pc, uint64_t *target)
{
    if (!target || (adrp & 0x9f000000) != 0x90000000 || (add & 0xff800000) != 0x91000000) return false;
    uint32_t reg = adrp & 31;
    if ((add & 31) != reg || ((add >> 5) & 31) != reg) return false;
    int64_t displacement = ((adrp >> 29) & 3) | (((adrp >> 5) & 0x7ffff) << 2);
    if (displacement & (1 << 20)) displacement -= (1 << 21);
    uint64_t immediate = (add >> 10) & 0xfff;
    if (add & (1 << 22)) immediate <<= 12;
    // Unsigned address arithmetic intentionally wraps for negative PC-relative displacements.
    *target = (pc & ~UINT64_C(0xfff)) + (uint64_t)(displacement * 4096) + immediate;
    return true;
}

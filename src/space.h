#ifndef SPACE_H
#define SPACE_H

//
// NOTE: How the window server describes the windows of a space query. A user window has no parent, a
// standard level (0, 3 or 8) and one of the tag combinations below; it is ordered in, or ordered out
// because it is minimized. The bits are the ones observed for such windows.
//

static inline bool space_window_has_user_level(uint32_t parent_wid, int level)
{
    return parent_wid == 0 && (level == 0 || level == 3 || level == 8);
}

static inline bool space_window_has_user_tags(uint64_t tags)
{
    return (tags & 0x1) || ((tags & 0x2) && (tags & 0x80000000));
}

static inline bool space_window_is_user_window(uint32_t parent_wid, int level, uint64_t tags, uint64_t attributes)
{
    return space_window_has_user_level(parent_wid, level) &&
           ((attributes & 0x2) || (tags & 0x400000000000000)) &&
           space_window_has_user_tags(tags);
}

static inline bool space_window_is_minimized_user_window(uint32_t parent_wid, int level, uint64_t tags, uint64_t attributes)
{
    return space_window_has_user_level(parent_wid, level) &&
           (attributes == 0x0 || attributes == 0x1) &&
           ((tags & 0x1000000000000000) || (tags & 0x300000000000000)) &&
           space_window_has_user_tags(tags);
}

uint32_t space_display_id(uint64_t sid);
uint32_t *space_window_list_for_connection(uint64_t *space_list, int space_count, int cid, int *count, bool include_minimized);
uint32_t *space_window_list(uint64_t sid, int *count, bool include_minimized);
bool space_is_user(uint64_t sid);
bool space_is_fullscreen(uint64_t sid);
bool space_is_visible(uint64_t sid);

#endif

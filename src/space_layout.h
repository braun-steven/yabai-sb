#ifndef SPACE_LAYOUT_H
#define SPACE_LAYOUT_H

#define SPACE_LAYOUT_MAX 8

//
// NOTE: The number of user spaces per display, for one display count (count). builtin_index is the entry
// for the builtin display ('b' suffix), or -1.
//

struct space_layout
{
    int count;
    int target[SPACE_LAYOUT_MAX];
    int builtin_index;
};

enum space_layout_result
{
    SPACE_LAYOUT_RESULT_DONE,
    SPACE_LAYOUT_RESULT_PERFORMED,
    SPACE_LAYOUT_RESULT_FAILED,
};

struct space_manager;

// implemented in Sources/Yabai/Shims/SpaceLayoutShims.swift (SpaceLayout in Sources/YabaiCore/SpaceLayout.swift)
bool space_layout_parse(char *text, int length, struct space_layout *layout);
void space_layout_targets(struct space_layout *layout, int builtin, int *target);
uint64_t space_layout_move_candidate(uint64_t *space_list, bool *user_list, int space_count, uint64_t visible_sid, bool from_end);
enum space_layout_result space_layout_reconcile(struct space_manager *sm);
void space_layout_schedule(double delay, bool reset_passes);

#endif

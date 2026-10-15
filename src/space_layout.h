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

// implemented in Sources/Yabai/Shims/SpaceLayoutShims.swift (SpaceLayout in Sources/YabaiCore/SpaceLayout.swift)
bool space_layout_parse(char *text, int length, struct space_layout *layout);

#endif

#ifndef SPACE_MANAGER
#define SPACE_MANAGER

enum space_op_error
{
    SPACE_OP_ERROR_SUCCESS              = 0,
    SPACE_OP_ERROR_MISSING_SRC          = 1,
    SPACE_OP_ERROR_MISSING_DST          = 2,
    SPACE_OP_ERROR_INVALID_SRC          = 3,
    SPACE_OP_ERROR_INVALID_DST          = 4,
    SPACE_OP_ERROR_INVALID_TYPE         = 5,
    SPACE_OP_ERROR_SAME_SPACE           = 6,
    SPACE_OP_ERROR_SAME_DISPLAY         = 7,
    SPACE_OP_ERROR_IN_MISSION_CONTROL   = 9,
    SPACE_OP_ERROR_SCRIPTING_ADDITION   = 10,
};

//
// NOTE: The space manager is Swift (Sources/Yabai/SpaceManager.swift).
//

#endif

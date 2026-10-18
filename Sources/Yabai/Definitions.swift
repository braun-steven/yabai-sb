//
// NOTE: The flags of views and windows, with the names and types under which Swift imported the C enums. Subphase 2.2
// of doc/swift-refactor.md turns them into OptionSets or Bools next to their models.
//

/// `enum view_flag`
struct view_flag: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let VIEW_LAYOUT         = view_flag(rawValue: 0x001)
let VIEW_TOP_PADDING    = view_flag(rawValue: 0x002)
let VIEW_BOTTOM_PADDING = view_flag(rawValue: 0x004)
let VIEW_LEFT_PADDING   = view_flag(rawValue: 0x008)
let VIEW_RIGHT_PADDING  = view_flag(rawValue: 0x010)
let VIEW_WINDOW_GAP     = view_flag(rawValue: 0x020)
let VIEW_ENABLE_PADDING = view_flag(rawValue: 0x080)
let VIEW_ENABLE_GAP     = view_flag(rawValue: 0x100)
let VIEW_IS_VALID       = view_flag(rawValue: 0x200)
let VIEW_IS_DIRTY       = view_flag(rawValue: 0x400)
let VIEW_AUTO_PADDING   = view_flag(rawValue: 0x1000)
let VIEW_IS_UNPADDED    = view_flag(rawValue: 0x2000)

/// `enum window_flag`
struct window_flag: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let WINDOW_SHADOW     = window_flag(rawValue: 0x01)
let WINDOW_FULLSCREEN = window_flag(rawValue: 0x02)
let WINDOW_MINIMIZE   = window_flag(rawValue: 0x04)
let WINDOW_FLOAT      = window_flag(rawValue: 0x08)
let WINDOW_STICKY     = window_flag(rawValue: 0x10)
let WINDOW_WINDOWED   = window_flag(rawValue: 0x20)
let WINDOW_MOVABLE    = window_flag(rawValue: 0x40)
let WINDOW_RESIZABLE  = window_flag(rawValue: 0x80)

/// `enum window_rule_flag`
struct window_rule_flag: RawRepresentable, Equatable, Sendable { var rawValue: UInt32 }
let WINDOW_RULE_MANAGED    = window_rule_flag(rawValue: 0x01)
let WINDOW_RULE_FULLSCREEN = window_rule_flag(rawValue: 0x02)
let WINDOW_RULE_MFF        = window_rule_flag(rawValue: 0x04)
let WINDOW_RULE_MFF_VALUE  = window_rule_flag(rawValue: 0x08)

#ifndef CPRIVATE_H
#define CPRIVATE_H

//
// NOTE: The private functions of SkyLight, HIServices and the mach runtime that yabai calls. The C unity build includes
// this header through yabai_c.h, and Swift imports it as the module CPrivate; Sources/Yabai/Platform wraps it. CPrivate.c
// only holds the function pointers that are resolved at runtime.
//
// Ownership: inside CF_IMPLICIT_BRIDGING_ENABLED, functions with Copy or Create in their name return a +1 object, the
// others a +0 one. A private function that returns a +1 object without Copy/Create in its name needs CF_RETURNS_RETAINED,
// both for Swift and for the static analyzer.
//
// Nullability: every pointer is nonnull unless it is marked _Nullable. These are private functions without documented
// contracts, so every returned object is _Nullable.
//

#include <stdbool.h>
#include <stdint.h>
#include <mach/mach.h>
#include <ApplicationServices/ApplicationServices.h>

// NOTE: The macro has no nullability, because a single annotated pointer makes clang require one on every pointer of the
// file that defines the callback.
#define CONNECTION_CALLBACK(name) void name(uint32_t type, void *data, size_t data_length, void *context, int cid)
typedef void connection_callback(uint32_t type, void *_Nullable data, size_t data_length, void *_Nullable context, int cid);

CF_IMPLICIT_BRIDGING_ENABLED
CF_ASSUME_NONNULL_BEGIN

// not exported by SkyLight: yabai.c resolves them with macho_find_symbol, and they stay NULL if that fails (CPrivate.c)
extern mach_port_t (*_Nullable CGSGetConnectionPortById)(int cid);
extern int64_t (*_Nullable SLSPerformAsynchronousBridgedWindowManagementOperation)(void *operation);

//
// NOTE: Swift reads the function pointer above through these functions: Swift 6 rejects references to a C global
// variable. The caller checks SLSHasBridgedWindowOperation first, as space_manager.c did.
//

static inline bool SLSHasBridgedWindowOperation(void)
{
    return SLSPerformAsynchronousBridgedWindowManagementOperation != NULL;
}

static inline int64_t SLSPerformBridgedWindowOperation(void *operation)
{
    return SLSPerformAsynchronousBridgedWindowManagementOperation(operation);
}

//
// NOTE: The window server clicks at a point through CGPostMouseEvent, which is deprecated and marked unavailable for Swift.
// The C wrapper keeps the call for the focus of a display (display_manager_focus_display, space_manager_focus_space_using_gesture),
// with the arguments of the C code: one click, the cursor moved.
//

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static inline void CGPostMouseEventC(CGPoint point, bool updateCursor, bool buttonDown)
{
    CGPostMouseEvent(point, updateCursor, 1, buttonDown);
}
#pragma clang diagnostic pop

extern mach_port_t mig_get_special_reply_port(void);
extern void mig_dealloc_special_reply_port(mach_port_t port);
extern AXUIElementRef _Nullable _AXUIElementCreateWithRemoteToken(CFDataRef data);
extern AXError _AXUIElementGetWindow(AXUIElementRef ref, uint32_t *wid);
extern int SLSMainConnectionID(void);
extern CGError SLSNewConnection(int zero, int *cid);
extern CGError SLSReleaseConnection(int cid);
extern CGError SLSRegisterConnectionNotifyProc(int cid, connection_callback *handler, uint32_t event, void *_Nullable context);
extern CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *frame);
extern int SLSGetWindowSubLevel(int cid, uint32_t wid);
extern CGError SLSGetWindowAlpha(int cid, uint32_t wid, float *alpha);
extern CGError SLSSetWindowAlpha(int cid, uint32_t wid, float alpha);
extern CGError SLSSetWindowResolution(int cid, uint32_t wid, double resolution);
extern CGError SLSCopyWindowProperty(int cid, uint32_t wid, CFStringRef property, CFTypeRef _Nullable *_Nonnull value);
extern CFStringRef _Nullable SLSCopyManagedDisplayForWindow(int cid, uint32_t wid);
extern CFStringRef _Nullable SLSCopyBestManagedDisplayForRect(int cid, CGRect rect);
extern CFArrayRef _Nullable SLSCopySpacesForWindows(int cid, int selector, CFArrayRef window_list);
extern CGError SLSDisableUpdate(int cid);
extern CGError SLSReenableUpdate(int cid);
extern CGError SLSNewWindow(int cid, int type, float x, float y, CFTypeRef region, uint32_t *wid);
extern CGError SLSNewWindowWithOpaqueShapeAndContext(int cid, int type, CFTypeRef region, CFTypeRef _Nullable opaque_shape, int options, uint64_t *tags, float x, float y, int tag_size, uint32_t *wid, void *_Nullable context);
extern CGError SLSReleaseWindow(int cid, uint32_t wid);
extern CGError SLSSetWindowTags(int cid, uint32_t wid, uint64_t *tags, int tag_size);
extern CGError SLSClearWindowTags(int cid, uint32_t wid, uint64_t *tags, int tag_size);
extern CGError SLSSetWindowShape(int cid, uint32_t wid, float x_offset, float y_offset, CFTypeRef shape);
extern CGError SLSSetWindowOpacity(int cid, uint32_t wid, bool opaque);
extern CGError SLSSetWindowBackgroundBlurRadiusStyle(int cid, uint32_t wid, int radius, int style);
extern CGError SLSOrderWindow(int cid, uint32_t wid, int mode, uint32_t rel_wid);
extern CGError SLSWindowIsOrderedIn(int cid, uint32_t wid, uint8_t *value);
extern CGError SLSSetWindowLevel(int cid, uint32_t wid, int level);
extern CGError SLSSetWindowSubLevel(int cid, uint32_t wid, int sub_level);
extern CGContextRef _Nullable SLWindowContextCreate(int cid, uint32_t wid, CFDictionaryRef _Nullable options);
extern CFTypeRef _Nullable CGRegionCreateEmptyRegion(void);
extern CGError CGSNewRegionWithRect(CGRect *rect, CF_RETURNS_RETAINED CFTypeRef _Nullable *_Nonnull region);
extern CFUUIDRef _Nullable CGDisplayCreateUUIDFromDisplayID(uint32_t did);
extern CFArrayRef _Nullable SLSCopyManagedDisplays(int cid);
extern uint64_t SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef uuid);
extern CFStringRef _Nullable SLSCopyActiveMenuBarDisplayIdentifier(int cid);
extern CGError SLSSetActiveMenuBarDisplayIdentifier(int cid, CFStringRef uuid, CFStringRef repeat_uuid);
extern CFStringRef _Nullable SLSCopyBestManagedDisplayForPoint(int cid, CGPoint point);
extern CGError SLSSetMenuBarInsetAndAlpha(int cid, double unused1, double unused2, float alpha);
extern CGError SLSGetMenuBarAutohideEnabled(int cid, int *enabled);
extern CGError SLSGetDisplayMenubarHeight(uint32_t did, uint32_t *height);
extern CGError SLSGetDockRectWithReason(int cid, CGRect *rect, int *reason);
extern Boolean CoreDockGetAutoHideEnabled(void);
extern void CoreDockGetOrientationAndPinning(int *orientation, int *pinning);
extern CFStringRef _Nullable SLSCopyManagedDisplayForSpace(int cid, uint64_t sid);
extern CGError SLSSpaceSetFrontPSN(int cid, uint64_t sid, ProcessSerialNumber psn);
extern int SLSSpaceGetType(int cid, uint64_t sid);
extern CFStringRef _Nullable SLSSpaceCopyName(int cid, uint64_t sid);
extern CFArrayRef _Nullable SLSCopyWindowsWithOptionsAndTags(int cid, uint32_t owner, CFArrayRef spaces, uint32_t options, uint64_t *set_tags, uint64_t *clear_tags);
extern int SLSGetSpaceManagementMode(int cid);
extern CFArrayRef _Nullable SLSCopyManagedDisplaySpaces(int cid);
extern CGError SLSProcessAssignToSpace(int cid, pid_t pid, uint64_t sid);
extern CGError SLSProcessAssignToAllSpaces(int cid, pid_t pid);
extern void SLSMoveWindowsToManagedSpace(int cid, CFArrayRef window_list, uint64_t sid);
extern CGError CoreDockSendNotification(CFStringRef notification, int unknown);
extern CGError SLSMoveWindow(int cid, uint32_t wid, CGPoint *point);
extern CFArrayRef _Nullable SLSCopyAssociatedWindows(int cid, uint32_t wid);
extern CF_RETURNS_RETAINED CFTypeRef _Nullable SLSWindowQueryWindows(int cid, CFArrayRef windows, int count);
extern CFTypeRef _Nullable SLSWindowQueryResultCopyWindows(CFTypeRef window_query);
extern int SLSWindowIteratorGetCount(CFTypeRef iterator);
extern bool SLSWindowIteratorAdvance(CFTypeRef iterator);
extern uint32_t SLSWindowIteratorGetParentID(CFTypeRef iterator);
extern uint32_t SLSWindowIteratorGetWindowID(CFTypeRef iterator);
extern uint64_t SLSWindowIteratorGetTags(CFTypeRef iterator);
extern uint64_t SLSWindowIteratorGetAttributes(CFTypeRef iterator);
extern int SLSWindowIteratorGetLevel(CFTypeRef iterator);
extern CF_RETURNS_RETAINED CFArrayRef _Nullable SLSWindowIteratorGetCornerRadii(CFTypeRef iterator);
extern OSStatus _SLPSGetFrontProcess(ProcessSerialNumber *psn);
extern CGError SLSGetWindowOwner(int cid, uint32_t wid, int *wcid);
extern CGError SLSGetConnectionPSN(int cid, ProcessSerialNumber *psn);
extern CGError SLSConnectionGetPID(int cid, pid_t *pid);
extern CGError SLSGetConnectionIDForPSN(int cid, ProcessSerialNumber *psn, int *psn_cid);
extern CGError _SLPSSetFrontProcessWithOptions(ProcessSerialNumber *psn, uint32_t wid, uint32_t mode);
extern CGError SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes);
extern OSStatus SLSFindWindowAndOwner(int cid, int zero, int one, int zero_again, CGPoint *screen_point, CGPoint *window_point, uint32_t *wid, int *wcid);
extern CGError SLSGetCurrentCursorLocation(int cid, CGPoint *point);
extern CGError SLSWindowSetShadowProperties(uint32_t wid, CFDictionaryRef options);
extern CGError SLSRequestNotificationsForWindows(int cid, uint32_t *window_list, int window_count);
extern CGError SLSSetWindowTransform(int cid, uint32_t wid, CGAffineTransform t);
extern CFTypeRef _Nullable SLSTransactionCreate(int cid);
extern CGError SLSTransactionCommit(CFTypeRef transaction, int synchronous);
extern CGError SLSTransactionSetWindowTransform(CFTypeRef transaction, uint32_t wid, int unknown, int unknown2, CGAffineTransform t);
extern CGError SLSTransactionOrderWindow(CFTypeRef transaction, uint32_t wid, int order, uint32_t rel_wid);
extern CGError SLSTransactionOrderWindowGroup(CFTypeRef transaction, uint32_t wid, int order, uint32_t rel_wid);
extern CGError SLSTransactionSetWindowAlpha(CFTypeRef transaction, uint32_t wid, float alpha);
extern CGError SLSTransactionSetWindowSystemAlpha(CFTypeRef transaction, uint32_t wid, float alpha);
extern CF_RETURNS_RETAINED CFArrayRef _Nullable SLSHWCaptureWindowList(int cid, uint32_t *window_list, int window_count, uint32_t options);
extern CGError SLSSpaceSetCompatID(int cid, uint64_t sid, int workspace);
extern CGError SLSSetWindowListWorkspace(int cid, uint32_t *window_list, int window_count, int workspace);

CF_ASSUME_NONNULL_END
CF_IMPLICIT_BRIDGING_DISABLED

#endif

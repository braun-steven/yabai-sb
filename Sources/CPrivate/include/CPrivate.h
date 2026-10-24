#ifndef CPRIVATE_H
#define CPRIVATE_H

//
// NOTE: The private functions of SkyLight, HIServices and the mach runtime that
// yabai calls. Swift imports this header as the module CPrivate;
// Sources/Yabai/Platform wraps it. CPrivate.c holds the function pointers that
// are resolved at runtime and SLSGetWindowSubLevelBounded, Notify.m the user
// notifications. The inline wrappers below keep the calls that Swift cannot
// make itself.
//
// Ownership: inside CF_IMPLICIT_BRIDGING_ENABLED, functions with Copy or Create
// in their name return a +1 object, the others a +0 one. A private function
// that returns a +1 object without Copy/Create in its name needs
// CF_RETURNS_RETAINED, both for Swift and for the static analyzer.
//
// Nullability: every pointer is nonnull unless it is marked _Nullable. These
// are private functions without documented contracts, so every returned object
// is _Nullable.
//

#include <ApplicationServices/ApplicationServices.h>
#include <crt_externs.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#ifdef __OBJC__
#include <AppKit/AppKit.h>
#endif

typedef void connection_callback(uint32_t type, void *_Nullable data,
                                 size_t data_length, void *_Nullable context,
                                 int cid);

CF_IMPLICIT_BRIDGING_ENABLED
CF_ASSUME_NONNULL_BEGIN

// not exported by SkyLight: Daemon.run resolves them with
// MachOSymbol.address(of:inImage:), and they stay NULL if that fails
// (CPrivate.c)
extern mach_port_t (*_Nullable CGSGetConnectionPortById)(int cid);
extern int64_t (
        *_Nullable SLSPerformAsynchronousBridgedWindowManagementOperation)(
    void *operation);

//
// NOTE: Swift reads the function pointer above through these functions: Swift 6
// rejects references to a C global variable. The caller checks
// SLSHasBridgedWindowOperation first (`SLS.bridgedMoveWindows`).
//

static inline bool SLSHasBridgedWindowOperation(void) {
  return SLSPerformAsynchronousBridgedWindowManagementOperation != NULL;
}

static inline int64_t SLSPerformBridgedWindowOperation(void *operation) {
  return SLSPerformAsynchronousBridgedWindowManagementOperation(operation);
}

//
// NOTE: The focus click of a display or space is a CGEvent (`postFocusClick`,
// MouseHandler.swift), not CGPostMouseEvent.
//

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// NOTE: CGWindowListCreate is unavailable to Swift. TabBar.swift uses the raw
// window-id array for hit testing.
static inline CF_RETURNS_RETAINED
    CFArrayRef _Nullable CGWindowListCreateC(CGWindowListOption options,
                                             CGWindowID relative_to_window) {
  return CGWindowListCreate(options, relative_to_window);
}

//
// NOTE: The Process Manager functions are deprecated since macOS 10.9, which
// makes them unavailable to Swift. These wrappers keep the calls of
// ProcessManager.swift and Application.swift.
//

static inline OSErr ProcessGetNextC(ProcessSerialNumber *psn) {
  return GetNextProcess(psn);
}

static inline pid_t ProcessGetPIDC(ProcessSerialNumber psn) {
  pid_t pid = 0;
  GetProcessPID(&psn, &pid);
  return pid;
}

// the processType of GetProcessInformation, 0 if the call fails
static inline OSType ProcessGetTypeC(ProcessSerialNumber psn) {
  ProcessInfoRec process_info = {.processInfoLength = sizeof(ProcessInfoRec)};
  GetProcessInformation(&psn, &process_info);
  return process_info.processType;
}

static inline CFStringRef _Nullable ProcessCopyNameC(ProcessSerialNumber psn) {
  CFStringRef process_name_ref = NULL;
  CopyProcessName(&psn, &process_name_ref);
  return process_name_ref;
}

static inline bool ProcessIsVisibleC(ProcessSerialNumber psn) {
  return IsProcessVisible(&psn) != 0;
}

// ProcessSerialNumber.isSame(as:) (Helpers.swift)
static inline bool ProcessSameC(ProcessSerialNumber *a,
                                ProcessSerialNumber *b) {
  Boolean result;
  SameProcess(a, b, &result);
  return result == 1;
}

// the event settings of the daemon at startup (Sources/Yabai/Yabai.swift); both
// functions are deprecated since macOS 10.6
static inline void
CGSetLocalEventsSuppressionIntervalC(CFTimeInterval seconds) {
  CGSetLocalEventsSuppressionInterval(seconds);
}

static inline void CGEnableEventStateCombiningC(bool combine) {
  CGEnableEventStateCombining(combine);
}
#pragma clang diagnostic pop

//
// NOTE: Swift 6 rejects references to the C globals stdout, stderr and environ
// (_NSGetEnviron is unavailable to Swift).
//

static inline FILE *stdout_global(void) { return stdout; }
static inline FILE *stderr_global(void) { return stderr; }
static inline char *_Nullable *_Nonnull environ_global(void) {
  return *_NSGetEnviron();
}

// a user notification titled yabai (Notify.m)
void NotifyC(const char *subtitle, const char *text);

// stores the functions that Daemon.run (Sources/Yabai/Yabai.swift) resolved
// with MachOSymbol.address(of:inImage:) (CPrivate.c)
void CPrivateSetResolvedFunctions(void *_Nullable get_connection_port_by_id,
                                  void *_Nullable bridged_operation);

#ifdef __OBJC__
//
// NOTE: Removing a key-value observation that is not registered throws an
// NSException, and Swift cannot catch one (it would end the process).
// Workspace.swift removes its observations through this wrapper, which ignores
// the exception as workspace.m did.
//

static inline void NSObjectRemoveObserverC(NSObject *object, NSObject *observer,
                                           NSString *key_path,
                                           void *_Nullable context) {
  @try {
    [object removeObserver:observer forKeyPath:key_path context:context];
  } @catch (NSException *__unused exception) {
  }
}

// NSApplicationLoad is unavailable to Swift; the daemon calls it at startup
// (Sources/Yabai/Yabai.swift)
static inline bool NSApplicationLoadC(void) { return NSApplicationLoad(); }
#endif

extern int csr_get_active_config(uint32_t *config);
extern mach_port_t mig_get_special_reply_port(void);
extern void mig_dealloc_special_reply_port(mach_port_t port);

//
// NOTE: The sub-level of a window, asked from the window server with the
// message that SLSGetWindowSubLevel sends, but with a bounded wait. False when
// CGSGetConnectionPortById was not resolved or the message failed;
// `WindowID.subLevel` (Sources/Yabai/Window.swift) then falls back to
// SLSGetWindowSubLevel. A C function in CPrivate.c, because Swift can neither
// lay out the packed message nor read NDR_record and the function pointer (C
// globals); a static inline body here made Swift emit its own NDR_record, a
// duplicate symbol in the release link.
//

bool SLSGetWindowSubLevelBounded(int cid, uint32_t wid, int *sub_level);
extern AXUIElementRef _Nullable _AXUIElementCreateWithRemoteToken(
    CFDataRef data);
extern AXError _AXUIElementGetWindow(AXUIElementRef ref, uint32_t *wid);
extern int SLSMainConnectionID(void);
extern CGError SLSNewConnection(int zero, int *cid);
extern CGError SLSReleaseConnection(int cid);
extern CGError SLSRegisterConnectionNotifyProc(int cid,
                                               connection_callback *handler,
                                               uint32_t event,
                                               void *_Nullable context);
extern CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *frame);
extern int SLSGetWindowSubLevel(int cid, uint32_t wid);
extern CGError SLSGetWindowAlpha(int cid, uint32_t wid, float *alpha);
extern CGError SLSSetWindowAlpha(int cid, uint32_t wid, float alpha);
extern CGError SLSSetWindowResolution(int cid, uint32_t wid, double resolution);
extern CGError SLSCopyWindowProperty(int cid, uint32_t wid,
                                     CFStringRef property,
                                     CFTypeRef _Nullable *_Nonnull value);
extern CFStringRef _Nullable SLSCopyManagedDisplayForWindow(int cid,
                                                            uint32_t wid);
extern CFStringRef _Nullable SLSCopyBestManagedDisplayForRect(int cid,
                                                              CGRect rect);
extern CFArrayRef _Nullable SLSCopySpacesForWindows(int cid, int selector,
                                                    CFArrayRef window_list);
extern CGError SLSDisableUpdate(int cid);
extern CGError SLSReenableUpdate(int cid);
extern CGError SLSNewWindow(int cid, int type, float x, float y,
                            CFTypeRef region, uint32_t *wid);
extern CGError SLSNewWindowWithOpaqueShapeAndContext(
    int cid, int type, CFTypeRef region, CFTypeRef _Nullable opaque_shape,
    int options, uint64_t *tags, float x, float y, int tag_size, uint32_t *wid,
    void *_Nullable context);
extern CGError SLSReleaseWindow(int cid, uint32_t wid);
extern CGError SLSSetWindowTags(int cid, uint32_t wid, uint64_t *tags,
                                int tag_size);
extern CGError SLSClearWindowTags(int cid, uint32_t wid, uint64_t *tags,
                                  int tag_size);
extern CGError SLSSetWindowShape(int cid, uint32_t wid, float x_offset,
                                 float y_offset, CFTypeRef shape);
extern CGError SLSSetWindowOpacity(int cid, uint32_t wid, bool opaque);
extern CGError SLSOrderWindow(int cid, uint32_t wid, int mode,
                              uint32_t rel_wid);
extern CGError SLSWindowIsOrderedIn(int cid, uint32_t wid, uint8_t *value);
extern CGError SLSSetWindowLevel(int cid, uint32_t wid, int level);
extern CGError SLSSetWindowSubLevel(int cid, uint32_t wid, int sub_level);
extern CGContextRef _Nullable SLWindowContextCreate(
    int cid, uint32_t wid, CFDictionaryRef _Nullable options);
extern CFTypeRef _Nullable CGRegionCreateEmptyRegion(void);
extern CGError
CGSNewRegionWithRect(CGRect *rect,
                     CF_RETURNS_RETAINED CFTypeRef _Nullable *_Nonnull region);
extern CFUUIDRef _Nullable CGDisplayCreateUUIDFromDisplayID(uint32_t did);
extern CFArrayRef _Nullable SLSCopyManagedDisplays(int cid);
extern uint64_t SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef uuid);
extern CFStringRef _Nullable SLSCopyActiveMenuBarDisplayIdentifier(int cid);
extern CGError SLSSetActiveMenuBarDisplayIdentifier(int cid, CFStringRef uuid,
                                                    CFStringRef repeat_uuid);
extern CFStringRef _Nullable SLSCopyBestManagedDisplayForPoint(int cid,
                                                               CGPoint point);
extern CGError SLSSetMenuBarInsetAndAlpha(int cid, double unused1,
                                          double unused2, float alpha);
extern CGError SLSGetMenuBarAutohideEnabled(int cid, int *enabled);
extern CGError SLSGetDisplayMenubarHeight(uint32_t did, uint32_t *height);
extern CGError SLSGetDockRectWithReason(int cid, CGRect *rect, int *reason);
extern Boolean CoreDockGetAutoHideEnabled(void);
extern void CoreDockGetOrientationAndPinning(int *orientation, int *pinning);
extern CFStringRef _Nullable SLSCopyManagedDisplayForSpace(int cid,
                                                           uint64_t sid);
extern CGError SLSSpaceSetFrontPSN(int cid, uint64_t sid,
                                   ProcessSerialNumber psn);
extern int SLSSpaceGetType(int cid, uint64_t sid);
extern CFStringRef _Nullable SLSSpaceCopyName(int cid, uint64_t sid);
extern CFArrayRef _Nullable SLSCopyWindowsWithOptionsAndTags(
    int cid, uint32_t owner, CFArrayRef spaces, uint32_t options,
    uint64_t *set_tags, uint64_t *clear_tags);
extern int SLSGetSpaceManagementMode(int cid);
extern CFArrayRef _Nullable SLSCopyManagedDisplaySpaces(int cid);
extern void SLSMoveWindowsToManagedSpace(int cid, CFArrayRef window_list,
                                         uint64_t sid);
extern CGError CoreDockSendNotification(CFStringRef notification, int unknown);
extern CGError SLSMoveWindow(int cid, uint32_t wid, CGPoint *point);
extern CFArrayRef _Nullable SLSCopyAssociatedWindows(int cid, uint32_t wid);
extern CF_RETURNS_RETAINED
    CFTypeRef _Nullable SLSWindowQueryWindows(int cid, CFArrayRef windows,
                                              int count);
extern CFTypeRef _Nullable SLSWindowQueryResultCopyWindows(
    CFTypeRef window_query);
extern int SLSWindowIteratorGetCount(CFTypeRef iterator);
extern bool SLSWindowIteratorAdvance(CFTypeRef iterator);
extern uint32_t SLSWindowIteratorGetParentID(CFTypeRef iterator);
extern uint32_t SLSWindowIteratorGetWindowID(CFTypeRef iterator);
extern uint64_t SLSWindowIteratorGetTags(CFTypeRef iterator);
extern uint64_t SLSWindowIteratorGetAttributes(CFTypeRef iterator);
extern int SLSWindowIteratorGetLevel(CFTypeRef iterator);
extern CF_RETURNS_RETAINED
    CFArrayRef _Nullable SLSWindowIteratorGetCornerRadii(CFTypeRef iterator);
extern OSStatus _SLPSGetFrontProcess(ProcessSerialNumber *psn);
extern CGError SLSGetWindowOwner(int cid, uint32_t wid, int *wcid);
extern CGError SLSGetConnectionPSN(int cid, ProcessSerialNumber *psn);
extern CGError SLSConnectionGetPID(int cid, pid_t *pid);
extern CGError SLSGetConnectionIDForPSN(int cid, ProcessSerialNumber *psn,
                                        int *psn_cid);
extern CGError _SLPSSetFrontProcessWithOptions(ProcessSerialNumber *psn,
                                               uint32_t wid, uint32_t mode);
extern CGError SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes);
extern OSStatus SLSFindWindowAndOwner(int cid, int zero, int one,
                                      int zero_again, CGPoint *screen_point,
                                      CGPoint *window_point, uint32_t *wid,
                                      int *wcid);
extern CGError SLSGetCurrentCursorLocation(int cid, CGPoint *point);
extern CGError SLSWindowSetShadowProperties(uint32_t wid,
                                            CFDictionaryRef options);
extern CGError SLSRequestNotificationsForWindows(int cid, uint32_t *window_list,
                                                 int window_count);
extern CFTypeRef _Nullable SLSTransactionCreate(int cid);
extern CGError SLSTransactionCommit(CFTypeRef transaction, int synchronous);
extern CGError SLSTransactionSetWindowTransform(CFTypeRef transaction,
                                                uint32_t wid, int unknown,
                                                int unknown2,
                                                CGAffineTransform t);
extern CGError SLSTransactionOrderWindowGroup(CFTypeRef transaction,
                                              uint32_t wid, int order,
                                              uint32_t rel_wid);
extern CGError SLSTransactionSetWindowAlpha(CFTypeRef transaction, uint32_t wid,
                                            float alpha);
extern CGError SLSTransactionSetWindowSystemAlpha(CFTypeRef transaction,
                                                  uint32_t wid, float alpha);
extern CF_RETURNS_RETAINED CFArrayRef _Nullable SLSHWCaptureWindowList(
    int cid, uint32_t *window_list, int window_count, uint32_t options);
extern CGError SLSSpaceSetCompatID(int cid, uint64_t sid, int workspace);
extern CGError SLSSetWindowListWorkspace(int cid, uint32_t *window_list,
                                         int window_count, int workspace);

CF_ASSUME_NONNULL_END
CF_IMPLICIT_BRIDGING_DISABLED

#endif

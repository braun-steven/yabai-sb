#include "CPrivate.h"
#import <Cocoa/Cocoa.h>

//
// NOTE: NSUserNotification is deprecated, and Swift warns about every use of a
// deprecated API, so the notifications stay ObjC (manual retain/release,
// -fno-objc-arc in Package.swift). Ported from src/misc/notify.h.
//

static bool g_notify_init;
static NSImage *g_notify_img;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface NotifyDelegate : NSObject <NSUserNotificationCenterDelegate>
@end

@implementation NotifyDelegate
- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center
     shouldPresentNotification:(NSUserNotification *)notification {
  return YES;
}
@end

static bool notify_init(void) {
  [[NSUserNotificationCenter defaultUserNotificationCenter]
      setDelegate:[NotifyDelegate alloc]];
  g_notify_img = [[[NSWorkspace sharedWorkspace]
      iconForFile:[[[NSBundle mainBundle] executablePath]
                      stringByResolvingSymlinksInPath]] retain];
  g_notify_init = true;

  return true;
}

void NotifyC(const char *subtitle, const char *text) {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  if (!g_notify_init)
    notify_init();

  NSUserNotification *notification = [[NSUserNotification alloc] init];
  notification.title = @"yabai";
  notification.subtitle = [NSString stringWithUTF8String:subtitle];
  notification.informativeText = [NSString stringWithUTF8String:text];
  //
  // NOTE: _identityImage and _identityImageHasBorder are private keys. An
  // unknown key on a future macOS raises NSUnknownKeyException, which Swift
  // cannot catch, so the calls are guarded here: a failure costs only the icon.
  //
  @try {
    [notification setValue:g_notify_img forKey:@"_identityImage"];
    [notification setValue:@(false) forKey:@"_identityImageHasBorder"];
  } @catch (NSException *exception) {
  }
  [[NSUserNotificationCenter defaultUserNotificationCenter]
      deliverNotification:notification];
  [notification release];

  [pool drain];
}

#pragma clang diagnostic pop

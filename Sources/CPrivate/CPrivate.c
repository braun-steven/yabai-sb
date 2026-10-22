#include "CPrivate.h"

mach_port_t (*CGSGetConnectionPortById)(int cid);
int64_t (*SLSPerformAsynchronousBridgedWindowManagementOperation)(
    void *operation);

void CPrivateSetResolvedFunctions(void *get_connection_port_by_id,
                                  void *bridged_operation) {
  CGSGetConnectionPortById = get_connection_port_by_id;
  SLSPerformAsynchronousBridgedWindowManagementOperation = bridged_operation;
}

bool SLSGetWindowSubLevelBounded(int cid, uint32_t wid, int *sub_level) {
  if (!CGSGetConnectionPortById)
    return false;

#pragma pack(push, 4)
  struct {
    mach_msg_header_t header;
    NDR_record_t NDR_record;
    uint32_t window_id;
    int32_t sub_level;
    int32_t padding1;
    int32_t padding2;
  } msg = {0};
#pragma pack(pop)

  msg.NDR_record = NDR_record;
  msg.window_id = wid;
  msg.header.msgh_bits = 0x1513;
  msg.header.msgh_remote_port = CGSGetConnectionPortById(cid);
  msg.header.msgh_local_port = mig_get_special_reply_port();
  msg.header.msgh_id = 0x76E3;

  //
  // NOTE: Bound the wait for the reply, so that a message the window server
  // does not answer (e.g. an unknown msgh_id on a new macOS release) can not
  // block the event loop forever. Like MIG-generated code, the special reply
  // port is destroyed on failure so that a late reply can not be received by
  // the next call on this thread.
  //

  mach_port_t reply_port = msg.header.msgh_local_port;
  kern_return_t kr =
      mach_msg(&msg.header, MACH_SEND_MSG | MACH_RCV_MSG | MACH_RCV_TIMEOUT,
               0x24, 0x30, reply_port, 100, 0);
  if (kr != MACH_MSG_SUCCESS) {
    mig_dealloc_special_reply_port(reply_port);
    return false;
  }

  *sub_level = msg.sub_level;
  return true;
}

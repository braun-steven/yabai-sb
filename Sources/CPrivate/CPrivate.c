#include "CPrivate.h"

mach_port_t (*CGSGetConnectionPortById)(int cid);
int64_t (*SLSPerformAsynchronousBridgedWindowManagementOperation)(void *operation);

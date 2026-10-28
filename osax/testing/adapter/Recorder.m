#include "include/RecordingAdapter.h"
#include <OSAXCore.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>

// Nothing here resolves private frameworks or touches real windows. Recording
// the exact validated adapter input preserves command/entry order.
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t digest, commands;
static _Atomic uint64_t allocations;
typedef void (*logger)(uint32_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t,
                       uint32_t);
static logger *logger_slot;
static pthread_t interrupted_server;
static struct sigaction previous_signal;
static volatile sig_atomic_t interruptions;
static int interrupted_fd;

static void interrupt_handler(int signal_number) {
  (void)signal_number;
  ++interruptions;
}
static void *interrupted_serve(void *unused) {
  (void)unused;
  // Swift Testing/sanitizer workers may start with SIGUSR1 blocked. Unblock it
  // on this disposable pthread only; inheriting that mask would make the
  // interruption test exercise no interruptions.
  sigset_t unblocked;
  sigemptyset(&unblocked);
  sigaddset(&unblocked, SIGUSR1);
  pthread_sigmask(SIG_UNBLOCK, &unblocked, NULL);
  sa_swift_serve(interrupted_fd);
  close(interrupted_fd);
  return NULL;
}

bool sa_test_interrupt_begin(int fd) {
  struct sigaction action = {.sa_handler = interrupt_handler};
  sigemptyset(&action.sa_mask);
  if (sigaction(SIGUSR1, &action, &previous_signal) != 0)
    return false;
  interruptions = 0;
  interrupted_fd = fd;
  if (pthread_create(&interrupted_server, NULL, interrupted_serve, NULL) == 0)
    return true;
  sigaction(SIGUSR1, &previous_signal, NULL);
  return false;
}

int sa_test_interrupt_signal(void) {
  return pthread_kill(interrupted_server, SIGUSR1);
}
int sa_test_interrupt_end(void) {
  pthread_join(interrupted_server, NULL);
  sigaction(SIGUSR1, &previous_signal, NULL);
  return interruptions;
}

static void allocation_log(uint32_t type, uintptr_t a, uintptr_t b, uintptr_t c,
                           uintptr_t result, uint32_t skip) {
  (void)a;
  (void)b;
  (void)c;
  (void)skip;
  // Darwin malloc_logger type 2 is allocation (also present for successful
  // realloc/calloc).
  if ((type & 2) && result)
    atomic_fetch_add_explicit(&allocations, 1, memory_order_relaxed);
}

bool sa_test_allocations_start(void) {
  logger_slot = (logger *)dlsym(RTLD_DEFAULT, "malloc_logger");
  if (!logger_slot || *logger_slot)
    return false;
  atomic_store(&allocations, 0);
  *logger_slot = allocation_log;
  return true;
}

uint64_t sa_test_allocations_stop(void) {
  if (logger_slot && *logger_slot == allocation_log)
    *logger_slot = NULL;
  return atomic_load(&allocations);
}

static void record(const void *bytes, size_t length) {
  for (size_t i = 0; i < length; ++i)
    digest = (digest ^ ((const uint8_t *)bytes)[i]) * UINT64_C(1099511628211);
}

void sa_test_reset(void) {
  pthread_mutex_lock(&lock);
  digest = UINT64_C(14695981039346656037);
  commands = 0;
  pthread_mutex_unlock(&lock);
}

uint32_t sa_native_attributes(void) { return OSAX_ATTRIB_ALL; }
const char *sa_native_version(void) { return "recording"; }
uint8_t sa_native_dispatch(const uint8_t *message, size_t length) {
  pthread_mutex_lock(&lock);
  ++commands;
  record(message, length);
  pthread_mutex_unlock(&lock);
  if (message[0] == SA_OPCODE_WINDOW_FOCUS)
    return SA_REPLY_UNSUPPORTED;
  return SA_REPLY_ACCEPTED;
}

uint64_t sa_test_digest(void) {
  pthread_mutex_lock(&lock);
  uint64_t value = digest;
  pthread_mutex_unlock(&lock);
  return value;
}
uint64_t sa_test_commands(void) {
  pthread_mutex_lock(&lock);
  uint64_t value = commands;
  pthread_mutex_unlock(&lock);
  return value;
}
void sa_test_memory(uint64_t *blocks, uint64_t *bytes, uint64_t *resident) {
  malloc_statistics_t stats;
  malloc_zone_statistics(NULL, &stats);
  *blocks = stats.blocks_in_use;
  *bytes = stats.size_in_use;
  mach_task_basic_info_data_t info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  *resident = task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                        (task_info_t)&info, &count) == KERN_SUCCESS
                  ? info.resident_size
                  : 0;
}

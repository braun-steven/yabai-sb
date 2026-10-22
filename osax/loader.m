#include "common.h"
#include "core/IO.h"
#include <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <pwd.h>
#include <stdio.h>
#include <sys/un.h>
#include <unistd.h>

#include <ptrauth.h>
#ifdef SA_LOADER_TESTING
#include "testing/loader/Mocks.h"
#endif
kern_return_t (*_thread_convert_thread_state)(
    thread_act_t thread, int direction, thread_state_flavor_t flavor,
    thread_state_t in_state, mach_msg_type_number_t in_stateCnt,
    thread_state_t out_state, mach_msg_type_number_t *out_stateCnt);

static char *payload_path = "/Library/ScriptingAdditions/yabai.osax/Contents/"
                            "Resources/payload.bundle/Contents/MacOS/payload";

//
// :Attribution
//
// The arm64e injection path is based on work by Jeremy Legendre
// (https://github.com/jslegendre)
//

extern const char sa_bootstrap_start[], sa_bootstrap_end[];
extern const char sa_bootstrap_create[], sa_bootstrap_open[],
    sa_bootstrap_exit[];
extern const char sa_bootstrap_threadid[], sa_bootstrap_context[],
    sa_bootstrap_path[];

struct bootstrap_result {
  int32_t create_result;
  uint32_t completed;
  uint64_t handle;
  uint64_t thread_id;
};

// Enumerating thread identifiers rather than just checking instruction pointers
// is important: a worker can temporarily be outside our code in a signal
// handler and later return into it.
static bool worker_finished(mach_port_t task, uint64_t identifier) {
#ifdef SA_LOADER_TESTING
  return sa_mock_worker_finished(task, identifier);
#else
  if (!identifier)
    return false;
  thread_act_array_t threads = NULL;
  mach_msg_type_number_t count = 0;
  if (task_threads(task, &threads, &count) != KERN_SUCCESS)
    return false;
  bool found = false, valid = true;
  for (mach_msg_type_number_t i = 0; i < count; ++i) {
    thread_identifier_info_data_t info;
    mach_msg_type_number_t size = THREAD_IDENTIFIER_INFO_COUNT;
    if (thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&info,
                    &size) != KERN_SUCCESS)
      valid = false;
    else if (info.thread_id == identifier)
      found = true;
    mach_port_deallocate(mach_task_self(), threads[i]);
  }
  vm_deallocate(mach_task_self(), (vm_address_t)threads,
                count * sizeof(thread_t));
  return valid && !found;
#endif
}

static bool payload_ready(void) {
#ifdef SA_LOADER_TESTING
  return sa_mock_payload_ready();
#else
  const char *sudo_uid = getenv("SUDO_UID");
  if (!sudo_uid)
    return false;
  char *end;
  errno = 0;
  unsigned long uid = strtoul(sudo_uid, &end, 10);
  if (errno || *end || end == sudo_uid || uid > UINT32_MAX)
    return false;
  struct passwd *user = getpwuid((uid_t)uid);
  if (!user)
    return false;
  struct sockaddr_un address = {.sun_family = AF_UNIX};
  int length = snprintf(address.sun_path, sizeof(address.sun_path),
                        SA_SOCKET_PATH_FMT, user->pw_name);
  if (length < 0 || (size_t)length >= sizeof(address.sun_path))
    return false;
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0)
    return false;
  bool result = false;
  uint64_t deadline = sa_io_now() + (uint64_t)SA_REQUEST_TIMEOUT_MS * 1000000;
  if (!sa_io_prepare(fd))
    goto done;
  int status = connect(fd, (struct sockaddr *)&address, sizeof(address));
  if (status < 0) {
    if (errno != EINPROGRESS && errno != EAGAIN)
      goto done;
    if (!sa_io_wait(fd, POLLOUT, deadline))
      goto done;
    int error = 0;
    socklen_t size = sizeof(error);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) != 0 || error)
      goto done;
  }
  uint8_t request[] = {1, 0, SA_OPCODE_HANDSHAKE};
  if (!sa_io_transfer(fd, request, sizeof(request), true, deadline))
    goto done;
  uint8_t response[sizeof(OSAX_VERSION) + sizeof(uint32_t) + 1];
  if (!sa_io_transfer(fd, response, sizeof(response), false, deadline))
    goto done;
  if (memcmp(response, OSAX_VERSION, sizeof(OSAX_VERSION)) != 0 ||
      response[sizeof(response) - 1] != '\n')
    goto done;
  uint32_t attributes;
  memcpy(&attributes, response + sizeof(OSAX_VERSION), sizeof(attributes));
  result = (attributes & OSAX_ATTRIB_ALL) == OSAX_ATTRIB_ALL;
done:
  close(fd);
  return result;
#endif
}

static pid_t get_dock_pid(void) {
#ifdef SA_LOADER_TESTING
  return 4242;
#else
  NSArray *list = [NSRunningApplication
      runningApplicationsWithBundleIdentifier:@"com.apple.dock"];

  if (list.count == 1) {
    NSRunningApplication *dock = list[0];
    if ([dock isFinishedLaunching] == YES) {
      return [dock processIdentifier];
    }
  }

  return 0;
#endif
}

int main(void) {
  int result = 1;
  mach_port_t task = MACH_PORT_NULL;
  thread_act_t conversion_thread = MACH_PORT_NULL, bootstrap = MACH_PORT_NULL;
  mach_vm_address_t code = 0, stack = 0, context = 0;
  const mach_vm_size_t stack_size = 64 * 1024;
  size_t code_size = (size_t)(sa_bootstrap_end - sa_bootstrap_start);
  char *template = NULL;
  bool started = false, parked = false, finished = false;
  struct bootstrap_result state = {.create_result = -1};
  pid_t pid = get_dock_pid();
  if (!pid) {
    fprintf(stderr, "could not locate Dock.app pid\n");
    goto cleanup;
  }

  kern_return_t error = task_for_pid(mach_task_self(), pid, &task);
  if (error != KERN_SUCCESS) {
    fprintf(stderr, "could not retrieve Dock task port: %s\n",
            mach_error_string(error));
    goto cleanup;
  }
  if (mach_vm_allocate(task, &stack, stack_size, VM_FLAGS_ANYWHERE) !=
          KERN_SUCCESS ||
      mach_vm_allocate(task, &context, sizeof(state), VM_FLAGS_ANYWHERE) !=
          KERN_SUCCESS ||
      mach_vm_allocate(task, &code, code_size, VM_FLAGS_ANYWHERE) !=
          KERN_SUCCESS) {
    fprintf(stderr, "could not allocate bootstrap memory\n");
    goto cleanup;
  }
  template = malloc(code_size);
  if (!template)
    goto cleanup;
  memcpy(template, sa_bootstrap_start, code_size);
  const char *slots[] = {sa_bootstrap_create, sa_bootstrap_open,
                         sa_bootstrap_exit, sa_bootstrap_threadid};
  const char *symbols[] = {"pthread_create_from_mach_thread", "dlopen",
                           "pthread_exit", "pthread_threadid_np"};
  for (size_t i = 0; i < sizeof(slots) / sizeof(slots[0]); ++i) {
    void *symbol = dlsym(RTLD_DEFAULT, symbols[i]);
    if (!symbol) {
      fprintf(stderr, "could not resolve %s\n", symbols[i]);
      goto cleanup;
    }
    uint64_t address =
        (uint64_t)ptrauth_strip(symbol, ptrauth_key_function_pointer);
    memcpy(template + (slots[i] - sa_bootstrap_start), &address,
           sizeof(address));
  }
  if (strlen(payload_path) >= 256)
    goto cleanup;
  memcpy(template + (sa_bootstrap_context - sa_bootstrap_start), &context,
         sizeof(context));
  memcpy(template + (sa_bootstrap_path - sa_bootstrap_start), payload_path,
         strlen(payload_path) + 1);
  if (mach_vm_write(task, context, (vm_offset_t)&state, sizeof(state)) !=
          KERN_SUCCESS ||
      mach_vm_write(task, code, (vm_offset_t) template,
                    (mach_msg_type_number_t)code_size) != KERN_SUCCESS ||
      mach_vm_protect(task, code, code_size, false,
                      VM_PROT_READ | VM_PROT_EXECUTE) != KERN_SUCCESS) {
    fprintf(stderr, "could not prepare bootstrap memory\n");
    goto cleanup;
  }

  void *handle =
      dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_NOW | RTLD_LOCAL);
  if (handle) {
    _thread_convert_thread_state = dlsym(handle, "thread_convert_thread_state");
    dlclose(handle);
  }
  if (!_thread_convert_thread_state) {
    fprintf(stderr, "could not resolve thread_convert_thread_state\n");
    goto cleanup;
  }
  arm_thread_state64_t thread_state = {}, machine_state = {};
  mach_msg_type_number_t machine_count = ARM_THREAD_STATE64_COUNT;
  __darwin_arm_thread_state64_set_pc_fptr(
      thread_state,
      ptrauth_sign_unauthenticated((void *)code, ptrauth_key_asia, 0));
  __darwin_arm_thread_state64_set_sp(thread_state, stack + stack_size / 2);
  error = thread_create(task, &conversion_thread);
  if (error != KERN_SUCCESS)
    goto mach_failure;
  error = _thread_convert_thread_state(
      conversion_thread, 2, ARM_THREAD_STATE64, (thread_state_t)&thread_state,
      ARM_THREAD_STATE64_COUNT, (thread_state_t)&machine_state, &machine_count);
  if (error != KERN_SUCCESS)
    goto mach_failure;
  thread_terminate(conversion_thread);
  mach_port_deallocate(mach_task_self(), conversion_thread);
  conversion_thread = MACH_PORT_NULL;
  error = thread_create_running(task, ARM_THREAD_STATE64,
                                (thread_state_t)&machine_state, machine_count,
                                &bootstrap);
  if (error != KERN_SUCCESS)
    goto mach_failure;
  started = true;

  uint64_t deadline = sa_io_now() + UINT64_C(5000000000);
  while (sa_io_now() < deadline) {
    mach_vm_size_t received = 0;
    error = mach_vm_read_overwrite(task, context, sizeof(state),
                                   (mach_vm_address_t)&state, &received);
    if (error != KERN_SUCCESS || received != sizeof(state))
      break;
    parked = state.create_result != -1;
    if (parked && state.create_result != 0) {
      fprintf(stderr, "remote pthread creation failed: %d\n",
              state.create_result);
      finished = true; // No worker was created.
      goto cleanup;
    }
    if (parked && state.completed && worker_finished(task, state.thread_id)) {
      finished = true;
      if (!state.handle) {
        fprintf(stderr, "remote dlopen failed\n");
        goto cleanup;
      }
      if (!payload_ready()) {
        fprintf(
            stderr,
            "payload did not report the expected version and capabilities\n");
        goto cleanup;
      }
      result = 0;
      goto cleanup;
    }
    usleep(10000);
  }
  fprintf(stderr, "timed out waiting for remote payload completion\n");
  goto cleanup;

mach_failure:
  fprintf(stderr, "remote thread setup failed: %s\n", mach_error_string(error));
cleanup:
  if (conversion_thread) {
    thread_terminate(conversion_thread);
    mach_port_deallocate(mach_task_self(), conversion_thread);
  }
  if (bootstrap) {
    if (parked) {
      // The raw thread is now in the local bootstrap spin, with no libpthread
      // call in flight.
      if (thread_terminate(bootstrap) != KERN_SUCCESS) {
        finished = false;
        result = 1;
      }
    }
    mach_port_deallocate(mach_task_self(), bootstrap);
  }
  // On an indeterminate timeout a worker may still execute our template or use
  // its context. Leave those remote allocations intact rather than turning a
  // loading failure into a Dock UAF.
  if (!started || (parked && finished)) {
    if (code)
      mach_vm_deallocate(task, code, code_size);
    if (stack)
      mach_vm_deallocate(task, stack, stack_size);
    if (context)
      mach_vm_deallocate(task, context, sizeof(state));
  } else {
    fprintf(stderr, "leaving bootstrap memory allocated because remote "
                    "execution is not confirmed finished\n");
  }
  free(template);
  if (task)
    mach_port_deallocate(mach_task_self(), task);
  return result;
}

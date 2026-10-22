// Compile the actual loader control flow against a simulated Mach task. No
// operation in this target can obtain a real task port, execute remote code,
// connect to the SA socket or restart Dock.
#define SA_LOADER_TESTING 1
#define main sa_loader_main
#include "../../loader.m"

static int test_mode, allocations_made, deallocations, terminations;
static uint64_t elapsed;

void sa_loader_test_mode(int mode) {
  test_mode = mode;
  allocations_made = deallocations = terminations = 0;
  elapsed = 0;
}
int sa_loader_test_deallocations(void) { return deallocations; }
int sa_loader_test_terminations(void) { return terminations; }

kern_return_t sa_mock_task_for_pid(mach_port_t self, pid_t pid,
                                   mach_port_t *task) {
  (void)self;
  (void)pid;
  *task = 100;
  return KERN_SUCCESS;
}
kern_return_t sa_mock_allocate(vm_map_t task, mach_vm_address_t *address,
                               mach_vm_size_t size, int flags) {
  (void)task;
  (void)size;
  (void)flags;
  if (test_mode == 6 && allocations_made == 1)
    return KERN_RESOURCE_SHORTAGE;
  *address = (mach_vm_address_t)(++allocations_made * 0x10000);
  return KERN_SUCCESS;
}
kern_return_t sa_mock_write(vm_map_t task, mach_vm_address_t address,
                            vm_offset_t data, mach_msg_type_number_t size) {
  (void)task;
  (void)address;
  (void)data;
  (void)size;
  return KERN_SUCCESS;
}
kern_return_t sa_mock_protect(vm_map_t task, mach_vm_address_t address,
                              mach_vm_size_t size, boolean_t maximum,
                              vm_prot_t protection) {
  (void)task;
  (void)address;
  (void)size;
  (void)maximum;
  (void)protection;
  return KERN_SUCCESS;
}
kern_return_t sa_mock_read(vm_map_t task, mach_vm_address_t address,
                           mach_vm_size_t size, mach_vm_address_t data,
                           mach_vm_size_t *received) {
  (void)task;
  (void)address;
  struct bootstrap_result result = {
      .create_result = 0, .completed = 1, .handle = 1, .thread_id = 999};
  if (test_mode == 1)
    result.create_result = 12;
  if (test_mode == 2)
    result.completed = 0;
  if (test_mode == 3)
    result.handle = 0;
  if (test_mode == 5)
    result.create_result = -1;
  memcpy((void *)data, &result, (size_t)size);
  *received = size;
  return KERN_SUCCESS;
}
kern_return_t sa_mock_deallocate(vm_map_t task, mach_vm_address_t address,
                                 mach_vm_size_t size) {
  (void)task;
  (void)address;
  (void)size;
  ++deallocations;
  return KERN_SUCCESS;
}
kern_return_t sa_mock_create(task_t task, thread_act_t *thread) {
  (void)task;
  *thread = 101;
  return KERN_SUCCESS;
}
kern_return_t sa_mock_running(task_t task, int flavor, thread_state_t state,
                              mach_msg_type_number_t count,
                              thread_act_t *thread) {
  (void)task;
  (void)flavor;
  (void)state;
  (void)count;
  *thread = 102;
  return KERN_SUCCESS;
}
kern_return_t sa_mock_terminate(thread_act_t thread) {
  ++terminations;
  return test_mode == 8 && thread == 102 ? KERN_FAILURE : KERN_SUCCESS;
}
kern_return_t sa_mock_port(mach_port_t task, mach_port_name_t name) {
  (void)task;
  (void)name;
  return KERN_SUCCESS;
}
static kern_return_t convert(thread_act_t thread, int direction,
                             thread_state_flavor_t flavor, thread_state_t in,
                             mach_msg_type_number_t in_count,
                             thread_state_t out,
                             mach_msg_type_number_t *out_count) {
  (void)thread;
  (void)direction;
  (void)flavor;
  memcpy(out, in, in_count * sizeof(natural_t));
  *out_count = in_count;
  return test_mode == 9 ? KERN_FAILURE : KERN_SUCCESS;
}
void *sa_mock_symbol(void *handle, const char *name) {
  (void)handle;
  (void)name;
  return (void *)convert;
}
uint64_t sa_mock_now(void) { return elapsed; }
int sa_mock_sleep(useconds_t duration) {
  (void)duration;
  elapsed += UINT64_C(1000000000);
  return 0;
}
bool sa_mock_worker_finished(mach_port_t task, uint64_t identifier) {
  (void)task;
  (void)identifier;
  return test_mode != 4;
}
bool sa_mock_payload_ready(void) { return test_mode != 7; }

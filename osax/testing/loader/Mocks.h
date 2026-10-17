#include <stdbool.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>

void sa_loader_test_mode(int mode);
int sa_loader_test_deallocations(void);
int sa_loader_test_terminations(void);
int sa_loader_main(void);

kern_return_t sa_mock_task_for_pid(mach_port_t self, pid_t pid, mach_port_t *task);
kern_return_t sa_mock_allocate(vm_map_t task, mach_vm_address_t *address, mach_vm_size_t size, int flags);
kern_return_t sa_mock_write(vm_map_t task, mach_vm_address_t address, vm_offset_t data, mach_msg_type_number_t size);
kern_return_t sa_mock_protect(vm_map_t task, mach_vm_address_t address, mach_vm_size_t size, boolean_t maximum, vm_prot_t protection);
kern_return_t sa_mock_read(vm_map_t task, mach_vm_address_t address, mach_vm_size_t size, mach_vm_address_t data, mach_vm_size_t *received);
kern_return_t sa_mock_deallocate(vm_map_t task, mach_vm_address_t address, mach_vm_size_t size);
kern_return_t sa_mock_create(task_t task, thread_act_t *thread);
kern_return_t sa_mock_running(task_t task, int flavor, thread_state_t state, mach_msg_type_number_t count, thread_act_t *thread);
kern_return_t sa_mock_terminate(thread_act_t thread);
kern_return_t sa_mock_port(mach_port_t task, mach_port_name_t name);
void *sa_mock_symbol(void *handle, const char *name);
uint64_t sa_mock_now(void);
int sa_mock_sleep(useconds_t duration);
bool sa_mock_worker_finished(mach_port_t task, uint64_t identifier);
bool sa_mock_payload_ready(void);

#define task_for_pid sa_mock_task_for_pid
#define mach_vm_allocate sa_mock_allocate
#define mach_vm_write sa_mock_write
#define mach_vm_protect sa_mock_protect
#define mach_vm_read_overwrite sa_mock_read
#define mach_vm_deallocate sa_mock_deallocate
#define thread_create sa_mock_create
#define thread_create_running sa_mock_running
#define thread_terminate sa_mock_terminate
#define mach_port_deallocate sa_mock_port
#define dlsym sa_mock_symbol
#define sa_io_now sa_mock_now
#define usleep sa_mock_sleep

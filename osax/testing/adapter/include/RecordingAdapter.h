#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

void sa_test_reset(void);
uint64_t sa_test_digest(void);
uint64_t sa_test_commands(void);
void sa_test_memory(uint64_t *blocks, uint64_t *bytes, uint64_t *resident);
bool sa_test_allocations_start(void);
uint64_t sa_test_allocations_stop(void);
bool sa_test_interrupt_begin(int fd);
int sa_test_interrupt_signal(void);
int sa_test_interrupt_end(void);

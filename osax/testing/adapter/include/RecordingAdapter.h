#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

void sa_test_reset(bool swift_core);
void sa_test_fail(bool reads, bool writes);
uint64_t sa_test_digest(void);
uint64_t sa_test_commands(void);
float sa_test_alpha(uint32_t wid);
void sa_test_memory(uint64_t *blocks, uint64_t *bytes, uint64_t *resident);
bool sa_test_allocations_start(void);
uint64_t sa_test_allocations_stop(void);
bool sa_baseline_serve(int fd);
bool sa_test_interrupt_begin(bool swift_core, int fd);
int sa_test_interrupt_signal(void);
int sa_test_interrupt_end(void);

//
// NOTE: A single worker thread drains a lock-free queue of events and runs the handler of each one
// (event_handlers.c). Any thread may post an event.
//

static void *event_loop_run(void *context)
{
    struct event *head, *next;
    struct event_loop *event_loop = context;

    while (event_loop->is_running) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

        for (;;) {
            profile_begin();

            do {
                head = __atomic_load_n(&event_loop->head, __ATOMIC_RELAXED);
                next = __atomic_load_n(&head->next, __ATOMIC_RELAXED);
                if (!next) goto empty;
            } while (!__sync_bool_compare_and_swap(&event_loop->head, head, next));

            switch (__atomic_load_n(&next->type, __ATOMIC_RELAXED)) {
#define EVENT_TYPE_ENTRY(value) case value: EVENT_HANDLER_##value(__atomic_load_n(&next->context, __ATOMIC_RELAXED), __atomic_load_n(&next->param1, __ATOMIC_RELAXED)); break;
                EVENT_TYPE_LIST
#undef EVENT_TYPE_ENTRY
            }

            event_signal_flush();
            ts_reset();

            profile_end_and_print();
        }

empty:
        [pool drain];
        sem_wait(event_loop->semaphore);
    }

    return NULL;
}

void event_loop_post(struct event_loop *event_loop, enum event_type type, void *context, int param1)
{
    bool success;
    struct event *tail, *new_tail;

    new_tail = memory_pool_push(&event_loop->pool, sizeof(struct event));
    __atomic_store_n(&new_tail->type, type, __ATOMIC_RELEASE);
    __atomic_store_n(&new_tail->param1, param1, __ATOMIC_RELEASE);
    __atomic_store_n(&new_tail->context, context, __ATOMIC_RELEASE);
    __atomic_store_n(&new_tail->next, NULL, __ATOMIC_RELEASE);
    __asm__ __volatile__ ("" ::: "memory");

    do {
        tail = __atomic_load_n(&event_loop->tail, __ATOMIC_RELAXED);
        success = __sync_bool_compare_and_swap(&tail->next, NULL, new_tail);
    } while (!success);
    __sync_bool_compare_and_swap(&event_loop->tail, tail, new_tail);

    sem_post(event_loop->semaphore);
}

bool event_loop_begin(struct event_loop *event_loop)
{
    if (!memory_pool_init(&event_loop->pool, KILOBYTES(512))) return false;

    event_loop->semaphore = sem_open("yabai_event_loop_semaphore", O_CREAT, 0600, 0);
    sem_unlink("yabai_event_loop_semaphore");
    if (event_loop->semaphore == SEM_FAILED) return false;

    event_loop->head = memory_pool_push(&event_loop->pool, sizeof(struct event));
    event_loop->head->next = NULL;
    event_loop->tail = event_loop->head;

    event_loop->is_running = true;
    pthread_create(&event_loop->thread, NULL, &event_loop_run, event_loop);

    return true;
}

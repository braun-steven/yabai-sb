#ifndef PROCESS_MANAGER_H
#define PROCESS_MANAGER_H

struct process
{
    ProcessSerialNumber psn;
    pid_t pid;
    char *name;
    void *ns_application;
    int policy;
    int launch_attempts;
    bool launch_given_up;
    bool volatile terminated;
};

struct process_manager
{
    struct table process;
    EventTargetRef target;
    EventHandlerUPP handler;
    EventTypeSpec type[3];
    EventHandlerRef ref;
    pid_t front_pid;
    pid_t last_front_pid;
    EventTime switch_event_time;
    ProcessSerialNumber finder_psn;
};

//
// NOTE: terminated and ns_application are also written on other threads. Swift has no atomics on C memory, so the
// handlers read and write them through these. The key-value observer reads terminated with acquire, as workspace.m did.
//

static inline bool process_is_terminated(struct process *process) { return __atomic_load_n(&process->terminated, __ATOMIC_RELAXED); }
static inline bool process_is_terminated_acquire(struct process *process) { return __atomic_load_n(&process->terminated, __ATOMIC_ACQUIRE); }
static inline void process_set_terminated(struct process *process, bool terminated) { __atomic_store_n(&process->terminated, terminated, __ATOMIC_RELEASE); }
static inline void *process_ns_application(struct process *process) { return __atomic_load_n(&process->ns_application, __ATOMIC_RELAXED); }
static inline void process_set_ns_application(struct process *process, void *ns_application) { __atomic_store_n(&process->ns_application, ns_application, __ATOMIC_RELEASE); }

// implemented in Sources/Yabai/ProcessManager.swift
bool process_manager_begin(struct process_manager *pm);

#endif

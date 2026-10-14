#ifndef WORKSPACE_H
#define WORKSPACE_H

@interface workspace_context : NSObject {
}
- (id)init;
@end

struct process;
void *workspace_application_create_running_ns_application(struct process *process);
void workspace_application_destroy_running_ns_application(void *context, struct process *process);
void workspace_application_unobserve(void *context, struct process *process);
bool workspace_application_is_observable(struct process *process);
bool workspace_application_is_finished_launching(struct process *process);
void workspace_application_observe_finished_launching(void *context, struct process *process);
void workspace_application_observe_activation_policy(void *context, struct process *process);
void workspace_application_unobserve_finished_launching(void *context, struct process *process);
void workspace_application_unobserve_activation_policy(void *context, struct process *process);
int workspace_display_notch_height(uint32_t did);
pid_t workspace_get_dock_pid(void);
bool workspace_event_handler_begin(void **context);

#endif

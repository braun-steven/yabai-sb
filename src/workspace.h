#ifndef WORKSPACE_H
#define WORKSPACE_H

// implemented in Sources/Yabai/Workspace.swift
struct process;
bool workspace_application_is_observable(struct process *process);
void workspace_application_observe_activation_policy(struct process *process);
bool workspace_event_handler_begin(void);

#endif

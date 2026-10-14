#ifndef MESSAGE_H
#define MESSAGE_H

//
// NOTE: The socket of the daemon, the dispatch of a message to its domain and the config domain are Swift
// (Sources/Yabai/IPC/MessageLoop.swift, MessageConfig.swift). The handlers of the other domains are still C.
//

// implemented in Sources/Yabai/IPC/MessageLoop.swift
void handle_message(FILE *rsp, char *message);
bool message_loop_begin(char *socket_path);
void daemon_message_handle(int sockfd);

// implemented in Sources/Yabai/Shims/MessageShims.swift, for the golden replay of the C tests
char *client_encode_message(int argc, char **argv, int *size);

void handle_domain_display(FILE *rsp, struct token domain, char *message);
void handle_domain_space(FILE *rsp, struct token domain, char *message);
void handle_domain_window(FILE *rsp, struct token domain, char *message);
void handle_domain_query(FILE *rsp, struct token domain, char *message);
void handle_domain_rule(FILE *rsp, struct token domain, char *message);
void handle_domain_signal(FILE *rsp, struct token domain, char *message);

#endif

#ifndef MESSAGE_H
#define MESSAGE_H

//
// NOTE: The socket of the daemon, the dispatch of a message to its domain and the handlers of the domains are Swift
// (Sources/Yabai/IPC/).
//

// implemented in Sources/Yabai/IPC/MessageLoop.swift
bool message_loop_begin(char *socket_path);
void daemon_message_handle(int sockfd);

#endif

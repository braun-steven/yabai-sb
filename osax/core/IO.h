#ifndef SA_IO_H
#define SA_IO_H

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static inline uint64_t sa_io_now(void) {
  struct timespec value;
  clock_gettime(CLOCK_MONOTONIC, &value);
  return (uint64_t)value.tv_sec * 1000000000 + (uint64_t)value.tv_nsec;
}

static inline bool sa_io_prepare(int fd) {
  int flags = fcntl(fd, F_GETFL);
  int one = 1;
  return flags != -1 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 &&
         setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) == 0;
}

static inline bool sa_io_wait(int fd, short events, uint64_t deadline) {
  for (;;) {
    uint64_t now = sa_io_now();
    if (now >= deadline)
      return false;
    uint64_t remaining = (deadline - now + 999999) / 1000000;
    struct pollfd pfd = {.fd = fd, .events = events};
    int result =
        poll(&pfd, 1, (int)(remaining > INT_MAX ? INT_MAX : remaining));
    if (result < 0 && errno == EINTR)
      continue;
    return result > 0 && (pfd.revents & (events | POLLHUP)) != 0;
  }
}

static inline bool sa_io_transfer(int fd, void *buffer, size_t length,
                                  bool writing, uint64_t deadline) {
  size_t offset = 0;
  while (offset < length) {
    if (!sa_io_wait(fd, writing ? POLLOUT : POLLIN, deadline))
      return false;
    ssize_t count = writing
                        ? send(fd, (char *)buffer + offset, length - offset, 0)
                        : recv(fd, (char *)buffer + offset, length - offset, 0);
    if (count < 0 &&
        (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK))
      continue;
    if (count <= 0)
      return false;
    offset += (size_t)count;
  }
  return true;
}

#endif

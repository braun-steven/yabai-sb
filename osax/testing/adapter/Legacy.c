#include <OSAXCore.h>
#include <sys/socket.h>
#include <unistd.h>
#include <string.h>

// Baseline framing from 107feff6d0bb984b98e685e9278801df7de96015, osax/payload.m.
// Only valid fixtures are fed to this deliberately unhardened baseline. Its native operations
// use the same recording adapter. This is not a measurement of the old injected payload's fades.
static bool read_message(int sockfd, char *message, int *length)
{
    int bytes_read = 0;
    int bytes_to_read = 0;
    if (read(sockfd, &bytes_to_read, sizeof(int16_t)) == sizeof(int16_t)) {
        if (bytes_to_read >= SA_SOCKET_BUFF_LEN || bytes_to_read <= 0) return false;
        do {
            int cur_read = (int)read(sockfd, message + bytes_read, (size_t)(bytes_to_read - bytes_read));
            if (cur_read <= 0) break;
            bytes_read += cur_read;
        } while (bytes_read < bytes_to_read);
        *length = bytes_read;
        return bytes_read == bytes_to_read;
    }
    return false;
}

bool sa_baseline_serve(int fd)
{
    char message[SA_SOCKET_BUFF_LEN];
    int length;
    if (!read_message(fd, message, &length)) return false;
    (void)sa_native_dispatch((uint8_t *)message, (size_t)length);
    return true;
}

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

extern char **environ;

static int parse_descriptor(const char *text) {
    char *end = NULL;
    errno = 0;
    long value = strtol(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value < 0 ||
        value > INT_MAX) {
        return -1;
    }
    return (int)value;
}

static int write_all(int descriptor, const uint8_t *bytes, size_t count) {
    size_t offset = 0;
    while (offset < count) {
        ssize_t written = write(descriptor, bytes + offset, count - offset);
        if (written > 0) {
            offset += (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        return -1;
    }
    return 0;
}

static void report_exec_error(int descriptor, int error_number) {
    uint32_t value = (uint32_t)error_number;
    const uint8_t record[8] = {
        'K',
        'E',
        'X',
        '1',
        (uint8_t)((value >> 24) & 0xff),
        (uint8_t)((value >> 16) & 0xff),
        (uint8_t)((value >> 8) & 0xff),
        (uint8_t)(value & 0xff),
    };
    (void)write_all(descriptor, record, sizeof(record));
}

int main(int argc, char *argv[]) {
    if (argc < 4) {
        return 64;
    }

    int isolation_descriptor = parse_descriptor(argv[1]);
    int status_descriptor = parse_descriptor(argv[2]);
    if (isolation_descriptor < 0 || status_descriptor < 0) {
        return 64;
    }

    const uint8_t admitted = 'x';
    if (write_all(isolation_descriptor, &admitted, 1) != 0) {
        return 65;
    }
    (void)close(isolation_descriptor);

    int descriptor_flags = fcntl(status_descriptor, F_GETFD);
    if (descriptor_flags < 0 ||
        fcntl(status_descriptor, F_SETFD, descriptor_flags | FD_CLOEXEC) < 0) {
        int error_number = errno;
        report_exec_error(status_descriptor, error_number);
        return 66;
    }

    execve(argv[3], &argv[3], environ);
    int error_number = errno;
    report_exec_error(status_descriptor, error_number);
    return 126;
}

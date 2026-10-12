#define _POSIX_C_SOURCE 200809L
#include "lock_auth.h"
#include "sophia_launch_auth.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdlib.h>
#include <time.h>

static int now_msec(uint64_t *value) {
  struct timespec time;
  if (clock_gettime(CLOCK_MONOTONIC, &time))
    return -1;
  *value = (uint64_t)time.tv_sec * 1000 + (uint64_t)time.tv_nsec / 1000000;
  return 0;
}

int kleis_lock_authenticate(struct sophia_9p_client *role, int *relay_fd,
                            uint32_t *root) {
  const char *text = getenv("SOPHIA_LAUNCH_AUTH_FD");
  struct sophia_9p_client relay;
  struct sophia_la_client auth;
  size_t bytes = sophia_9p_storage_bytes(65536, 16);
  void *storage;
  uint64_t now, wake;
  unsigned fd = 0;
  int flags, result = -1;
  *relay_fd = -1;
  *root = UINT32_MAX;
  if (!text)
    return 0;
  if (!*text)
    return -1;
  for (; *text; ++text) {
    if (*text < '0' || *text > '9' ||
        fd > ((unsigned)INT_MAX - (unsigned)(*text - '0')) / 10)
      return -1;
    fd = fd * 10 + (unsigned)(*text - '0');
  }
  if (fd < 3 || (int)fd == role->fd)
    return -1;
  flags = fcntl((int)fd, F_GETFD);
  if (flags < 0)
    return -1;
  *relay_fd = (int)fd;
  if (fcntl((int)fd, F_SETFD, flags | FD_CLOEXEC) < 0)
    return -1;
  storage = malloc(bytes);
  if (!storage)
    return -1;
  if (now_msec(&now) ||
      sophia_9p_init(&relay, (int)fd, 65536, 16, 32, storage, bytes) ||
      sophia_la_init(&auth, role, &relay, "lock", "lock-provider", now))
    goto done;
  for (;;) {
    struct pollfd fds[2] = {
        {role->fd, POLLIN, 0}, {(int)fd, POLLIN, 0}};
    int timeout;
    if (now_msec(&now) || sophia_la_service(&auth, now, 1u << 20))
      break;
    if (sophia_la_ready(&auth)) {
      *root = sophia_la_root(&auth);
      result = 1;
      break;
    }
    if (sophia_9p_wants_write(role))
      fds[0].events |= POLLOUT;
    if (sophia_9p_wants_write(&relay))
      fds[1].events |= POLLOUT;
    wake = sophia_la_next_wake(&auth);
    timeout = wake <= now ? 0 : (int)(wake - now);
    if (poll(fds, 2, timeout) < 0 && errno != EINTR)
      break;
  }
  if (result < 0)
    sophia_la_cancel(&auth);
done:
  free(storage);
  return result;
}

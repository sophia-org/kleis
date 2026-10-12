#define _POSIX_C_SOURCE 200809L
/* Reuse the SDK's scripted wire peer, not its client-driving test. This checks
 * Kleis's real startup adapter and fd ownership; protected custody is separate. */
#define main sdk_launch_test_main
#include "../vendor/sophia-desktop-sdk/source/src/tests/launch_auth_test.c"
#undef main
#include "../src/kleis/lock_auth.h"
#include <signal.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>

static void exchange(int mode) {
  struct fixture f;
  pid_t child;
  int status, completed = 0;
  memset(&f, 0, sizeof f);
  f.mode = mode;
  assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, f.role));
  assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, f.relay));
  put(f.nonce, 1); put(f.nonce + 4, 1);
  child = fork();
  assert(child >= 0);
  if (!child) {
    struct sophia_9p_client wire;
    size_t bytes = sophia_9p_storage_bytes(65536, 16);
    void *storage = malloc(bytes);
    uint32_t root;
    int retained, result;
    char descriptor[32];
    close(f.role[1]); close(f.relay[1]);
    snprintf(descriptor, sizeof descriptor, "%d", f.relay[0]);
    assert(!setenv("SOPHIA_LAUNCH_AUTH_FD", descriptor, 1));
    assert(!sophia_9p_init(&wire, f.role[0], 65536, 16, 32, storage, bytes));
    result = kleis_lock_authenticate(&wire, &retained, &root);
    assert(retained == f.relay[0]);
    assert(fcntl(retained, F_GETFD) & FD_CLOEXEC);
    assert(result == (mode == 0 ? 1 : -1));
    assert((root != UINT32_MAX) == (mode == 0));
    close(retained); close(f.role[0]); free(storage);
    _exit(0);
  }
  /* Keep the parent's client ends until waitpid so the nonblocking scripted
   * peer does not mistake the child's completed close for a wire request. */
  for (unsigned i = 0; i < 7000; ++i) {
    struct timespec delay = {0, 1000000};
    if (waitpid(child, &status, WNOHANG) == child) { completed = 1; break; }
    peer(&f, 0); peer(&f, 1); nanosleep(&delay, NULL);
  }
  if (!completed) { kill(child, SIGKILL); waitpid(child, &status, 0); }
  assert(completed && WIFEXITED(status) && WEXITSTATUS(status) == 0);
  assert(f.root_attaches == (mode == 0 ? 1u : 0u));
  finish(&f);
}

int main(void) {
  struct sophia_9p_client wire = {0};
  const char *invalid[] = {"", "0", "1", "2", "-1", "+3", "3x", " 3", "2147483648"};
  uint32_t root;
  int retained;
  assert(!unsetenv("SOPHIA_LAUNCH_AUTH_FD"));
  assert(kleis_lock_authenticate(&wire, &retained, &root) == 0);
  for (unsigned i = 0; i < sizeof invalid / sizeof invalid[0]; ++i) {
    assert(!setenv("SOPHIA_LAUNCH_AUTH_FD", invalid[i], 1));
    assert(kleis_lock_authenticate(&wire, &retained, &root) == -1);
    assert(retained == -1 && root == UINT32_MAX);
  }
  exchange(0); /* verified root */
  exchange(2); /* relay refusal */
  exchange(3); /* role refusal */
  exchange(5); /* five-second silent-peer deadline */
  puts("kleis launch authentication: success, refusals, fd bounds and deadline passed");
}

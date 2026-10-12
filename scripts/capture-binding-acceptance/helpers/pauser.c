/*
 * Synthetic long-lived target for GreenBubbles binding acceptance (V1–V8).
 * Platform: macOS (also builds on Linux for smoke). NEVER named WeChat.
 *
 * Build:  cc -O0 -o gbiso-pauser pauser.c
 * Run:    ./gbiso-pauser [/absolute/path/to/db_storage/foo.db]
 *
 * If a path is given, opens it O_RDONLY and keeps the descriptor for the
 * whole lifetime so /usr/sbin/lsof can observe exactly one open db_storage
 * root (ProcessTargetBinding.assertStillBound requirement). Then pause()
 * forever until SIGTERM/SIGKILL from the harness.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc >= 2) {
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) {
      perror("gbiso-pauser: open");
      return 2;
    }
    /* Intentionally never close(fd): lsof must see the open .db. */
    (void)fd;
  }
  for (;;) {
    if (pause() < 0 && errno != EINTR) {
      return 3;
    }
  }
  return 0;
}

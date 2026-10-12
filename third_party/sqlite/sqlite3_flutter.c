/*
 * Build wrapper; sqlite3.c remains the unmodified upstream amalgamation.
 * SQLite's unixSleep ignores nanosleep's EINTR and reports the entire requested
 * duration as slept. Dart's SIGPROF can therefore consume a 5s busy_timeout in
 * milliseconds. Resume the remaining sleep so lock waits work in Flutter's
 * debug/profile runtimes as well as release.
 */
#ifndef _WIN32
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif
#include <errno.h>
#include <time.h>

static int sr_sqlite_nanosleep(
    const struct timespec *requested, struct timespec *remaining) {
  struct timespec pending = *requested;
  struct timespec rest = pending;
  int result;
  do {
    result = nanosleep(&pending, &rest);
    if (result == 0 || errno != EINTR) break;
    pending = rest;
  } while (1);
  if (result != 0 && remaining != NULL) *remaining = rest;
  return result;
}
#define nanosleep sr_sqlite_nanosleep
#endif

#include "sqlite3.c"

#ifndef _WIN32
#undef nanosleep
#endif

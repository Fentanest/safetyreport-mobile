# Bundled SQLite

SQLite 3.53.4, unmodified public-domain amalgamation from
https://sqlite.org/2026/sqlite-amalgamation-3530400.zip.

`sqlite3.c` SHA3-256:
`67f423e9ebbbdc473cbc4772c872ee6b89f31fde4ed0279a5c25d5f65c043a16`

Verified against https://sqlite.org/releaselog/3_53_4.html.
License: https://sqlite.org/copyright.html (public domain; source header retained).

The `sqlite3` Dart native-assets hook builds `sqlite3_flutter.c`, which includes
this unmodified source, for each target ABI. The wrapper resumes POSIX
`nanosleep` after EINTR: SQLite's `unixSleep` otherwise reports a full sleep even
when Dart's SIGPROF interrupts it, prematurely consuming `busy_timeout` in
debug/profile runtimes. Windows uses the original implementation.
Its default compile options include FTS5, but omit FTS3/4. `pubspec.yaml` adds
`SQLITE_ENABLE_FTS3` (also enables FTS4) and `SQLITE_ENABLE_FTS3_PARENTHESIS` to
preserve existing Android and imported virtual tables. No encryption or file
format conversion is introduced. Keep the source version, hash, runtime version
assertion and architecture documentation together when updating.

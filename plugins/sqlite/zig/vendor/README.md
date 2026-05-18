# Vendored SQLite amalgamation

- **Source**: <https://www.sqlite.org/2025/sqlite-amalgamation-3510000.zip>
- **Version**: SQLite `3.51.0` (`SQLITE_VERSION` in `sqlite3.h`)
- **Files**: `sqlite3.c` (amalgamation), `sqlite3.h` (public API). `shell.c`
  / `sqlite3ext.h` intentionally omitted (not needed for an embedded library).
- **sqlite3.c sha256**: `dc58f0b5b74e8416cc29b49163a00d6b8bf08a24dd4127652beaaae307bd1839`
- **License**: SQLite is in the **public domain** (<https://www.sqlite.org/copyright.html>) —
  no attribution or license file required, vendoring is unrestricted.

Vendored (vs. system `libsqlite3` or a Zig package) so the plugin builds
deterministically and identically on macOS / Linux / Windows with no system
dependency variance — the same approach `better-sqlite3` / `rusqlite (bundled)`
take. Compile options are set in `../build.zig` (`-DSQLITE_*` flags).

To upgrade: download the new amalgamation zip, replace `sqlite3.c`/`sqlite3.h`,
update the version + sha256 above.

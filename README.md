# sqlite3 — SQLite for Amber

A native-only Amber package for working with SQLite databases, implementing the
public API from `DESIGN-package-sqlite3-api-2026-07-02.md`.

```amber
import sqlite3
from sqlite3 import sql

sqlite3.open("data/app.db", busy_timeout: 2.seconds) |db|:
  db.execute("create table if not exists users(id integer primary key, name text, age integer)")
  db.insert(:users, columns: [:name, :age], values: [
    ["Ada", 36],
    {name: "Iris", age: 41}
  ])

  adults = db.select(:users,
    columns: [:id, :name],
    where: {age: [36, 41]},
    order: [[:name, :asc]]
  )

  db.transaction(mode: :immediate) |tx|:
    tx.execute("insert into users(name, age) values (?, ?)", params: ["June", 29])

  older = db.query(sql"""
    select id, name
    from users
    where age > #{30}
    order by id
    """)
```

## Architecture

The `amber_ext` ABI exposes only `null`/`Bool`/`Int`/`Float`/`Str`/`Bytes`/`List`
plus opaque foreign handles — no maps, no symbols, no keyword arguments. So the C
side ([`native/sqlite3_ext.c`](native/sqlite3_ext.c)) is a thin set of low-level
*leaves*: SQL arrives as a `Str`, bind values as a flat `List` of scalars, and
rows leave as a `List` of column-value `List`s. Everything a user touches —
name-indifferent row `Map`s, named parameters, keyword arguments, transactions,
the convenience SQL builders, and the typed error hierarchy — is built in Amber
([`src/sqlite3.am`](src/sqlite3.am)) over two private native-handle classes,
`Conn` (a `sqlite3*`) and `Stmt` (a `sqlite3_stmt*`).

This mirrors the design's first anchor: *the Amber source is the public API; C is
only the implementation of native-only leaves.*

SQLite itself is vendored as the official amalgamation
([`native/sqlite3.c`](native/sqlite3.c), v3.51.0) and statically linked, so a
consumer binary is self-contained and reproducible.

## Building & importing

This is a native-only package: `Database`, `Statement`, `Conn`, and `Stmt` are
`native class ... owned`, so a program that uses it must be built as a native
executable (`--target native`). In a bytecode build the native classes fail
closed with `NativeRequiredError`.

A consumer manifest lists this package's module + native extension. See
[`test/selftest.build.yaml`](test/selftest.build.yaml) for a complete example.
Build and run:

```sh
amberc build your.build.yaml --target native --out-dir out --cache-dir cache
./out/your.root.module
```

Capabilities: the package requires the `ffi.v1` profile feature (it links C).
Opening a database additionally uses `db`/`fs` host grants at runtime (design §11).

## What's implemented

Core connection layer (`Database`):

- `open` / `connect` / `memory`, block-scoped and handle-returning forms,
  `Str` or `fs.Path` database paths, `mode:`, `uri:`, `busy_timeout:`
  (numeric seconds or `TimePeriod`), `pragmas:`
- `exec`, `execute`, `execute_many`, `query`, `query_one`, `scalar`,
  `query_arrays`, `each`, `each_array`, `prepare`
- `transaction` (deferred/immediate/exclusive, commit-on-return /
  rollback-on-raise), nested `savepoint`s, `begin!` / `commit!` / `rollback!`
- `pragma` / `pragma!`, `changes` / `total_changes` / `last_insert_rowid`,
  `filename`, `readonly?`, `in_transaction?`, `busy_timeout!`, `interrupt!`,
  `close!` / `destroy!` / `closed?`
- name-indifferent row `Map`s (symbol and string keys), the array-row path
  (`query_arrays`) for duplicate labels, generic command-result keys
  (`affected_rows:` / `last_insert_id:` alongside the SQLite-specific keys)
- feature discovery: `features()`, live `json_available?` / `jsonb_available?` /
  `jsonb_each_available?` / `jsonb_tree_available?` probes

Query execution has a package-neutral instrumentation boundary. Install any
object implementing `instrument(execution, &execute)` with
`db.instrument_queries!(instrumenter)`. The callback receives a
`sqlite3.SqlExecution` containing `operation`, final prepared `sql`, and the
original `params`; it must invoke the supplied block and return its result.
High-level statement helpers and transaction commands pass through this
boundary, allowing logging, tracing, metrics, and OpenTelemetry spans without
coupling them to this package.

Prepared statements (`Statement`): `bind!`, `reset!`, `clear_bindings!`, `step`,
`step_array`, `execute`, `query`, `query_one`, `scalar`, `query_arrays`, `each`,
`each_array`, plus metadata (`columns`, `column_names`, `parameter_names`,
`readonly?`, `busy?`, …).

Parameter binding: positional (`List` / `Tuple`) and named (`Map` / `StrictMap`,
bare or prefixed keys) placeholders; values map per design §4.

Convenience query layer: `insert`, `insert_or_ignore`, `insert_or_replace`,
`upsert`, `update`, `delete`, `select`, `get`, with identifier quoting,
equality/`IN`/`IS NULL` predicate maps, `where` / `where_not`, `group_by`,
`having`, `order`, `limit` / `offset`, and `returning:`.

Typed SQL values & sanitization: the exportable `sql"""..."""` string-tag macro
that turns interpolants into bind parameters, `fragment(text, params)`,
`ident(name)`, `quote_identifier(name)`, and the `SqlFragment` / `SqlIdent`
opaque types, accepted in the core methods and convenience slots.

Error surface: the full hierarchy from design §12 is registered natively
(`Sqlite3.Error` … `Sqlite3.ConstraintError`, `BusyError`, `LockedError`,
`ReadOnlyError`, `RangeError`, `MisuseError`, `InterruptError`, `CorruptError`,
`TransactionError`, `Json*Error`), with SQLite result-code mapping. Rescue by the
registered name, e.g. `rescue Sqlite3.ConstraintError |e|:`.

Safety: `ATTACH` / `DETACH` / `VACUUM INTO` are rejected by the native layer
(design §11, §15); direct-execution helpers reject trailing SQL after the first
statement; `exec` is the trusted multi-statement path.

The self-test ([`test/selftest.am`](test/selftest.am)) exercises 34 end-to-end
behaviours across all of the above and is the package's conformance check.

## Deferred (not yet implemented)

These parts of the design are intentionally left for follow-up work and are
called out here for honesty:

- **Connection `Pool` / `PoolLease`** (design §7). The cross-native-thread
  affinity + cooperative-fiber pinning it specifies is a deep runtime
  integration; `features()` reports `pool: false`.
- **JSON/JSONB query-builder wrappers** `json()` / `jsonb()` and
  `to_json` / `to_jsonb` (design §9.4). The capability *probes* are implemented;
  the value wrappers are not.
- **The strict `--require-full-native` zero-fallback gate** (design §3). The
  package builds and runs correctly under `--target native`, but the rich Amber
  layer (maps, string building, closures) currently lowers with some VM fallback,
  so `native_graph_vm_fallback_code_count` is not yet 0. This tracks the native
  backend's breadth, not the package.

## Toolchain requirements

Building this package exercises language features that were fixed/added in the
Amber toolchain alongside it (forward references between module functions,
namespace-qualified calls `module.func()`, cross-module closure capture
preservation, `self` as a first-class value, and the `macro.v1` string-tag macro
profile). It requires an Amber toolchain that includes those fixes.

## Layout

```
amber.build.yaml        package manifest (module + native extension)
src/sqlite3.am          the public API, in Amber
native/sqlite3_ext.c    native leaves over the amber_ext ABI
native/sqlite3.c/.h     vendored SQLite amalgamation (3.51.0, public domain)
test/selftest.am        end-to-end conformance test (returns 34)
test/selftest.build.yaml  build manifest for the self-test
examples/basic.am       a small usage example
```

## License

The package code (`src/`, `native/sqlite3_ext.c`, tests, examples) is released
into the public domain (see [LICENSE](LICENSE)). The vendored SQLite amalgamation
is itself public domain (https://www.sqlite.org/copyright.html).

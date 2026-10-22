# sqlite3 — SQLite for Sputnik

A native-only Sputnik package for working with SQLite databases, implementing the
public API from `DESIGN-package-sqlite3-api-2026-07-02.md`.

```sputnik
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

For concurrent applications, use a pool directly as the database executor:

```sputnik
import task
import sqlite3

sqlite3.pool("data/app.db", min_size: 1, max_size: 10) |pool|:
  jobs = user_ids.map |id|:
    task.spawn:
      pool.get(:users, where: {id: id})

  users = jobs.map |job|: job.wait()
```

## Architecture

Online backups use `source.backup_into(destination, timeout: 30.0)`, where both
arguments are separately opened `Database` objects outside transactions. The
method copies SQLite's consistent snapshot, including committed WAL contents,
without copying live database files. It retries BUSY/LOCKED within the deadline
and observes task cancellation. The caller manages destination creation, private
permissions and file/directory durability. Same-connection and transactional
backups raise `TransactionError`; see `test/backup_selftest.s`.

The `sputnik_ext` ABI exposes only `null`/`Bool`/`Int`/`Float`/`Str`/`Bytes`/`List`
plus opaque foreign handles — no maps, no symbols, no keyword arguments. So the C
side ([`native/sqlite3_ext.c`](native/sqlite3_ext.c)) is a thin set of low-level
*leaves*: SQL arrives as a `Str`, bind values as a flat `List` of scalars, and
rows leave as a `List` of column-value `List`s. Everything a user touches —
name-indifferent row `Map`s, named parameters, keyword arguments, transactions,
the convenience SQL builders, and the typed error hierarchy — is built in Sputnik
([`src/sqlite3.s`](src/sqlite3.s)) over private native-handle classes for
connections, statements, shared pool state, and generation-checked leases.

This mirrors the design's first anchor: *the Sputnik source is the public API; C is
only the implementation of native-only leaves.*

SQLite itself is vendored as the official amalgamation
([`native/sqlite3.c`](native/sqlite3.c), v3.51.0) and statically linked, so a
consumer binary is self-contained and reproducible.

## Building & importing

This is a native-only package: its low-level connection, statement, pool, and
lease handles are native classes, so a program that uses it must be built as a
native executable (`--target native`). In a bytecode build the native classes
fail closed with `NativeRequiredError`.

A consumer manifest lists this package's module + native extension. See
[`test/selftest.build.yaml`](test/selftest.build.yaml) for a complete example.
Build and run:

```sh
sputnik build your.build.yaml --target native --require-full-native \
  --out-dir out --cache-dir cache
./out/your.root.module
```

The core, pool, concurrent example, and `orm` integration graphs all pass
the strict full-native gate with zero fallback code objects. Pool contention is
declared as blocking FFI: the common checkout stays on the nonblocking fast
path, while an exhausted pool waits on a native condition through Sputnik's
blocking executor. VM strands park during that wait, and fully-native calls do
not retain the serialized runtime bridge lock.

Capabilities: the package requires the `ffi.v1` profile feature (it links C).
Opening a database additionally uses `db`/`fs` host grants at runtime (design §11).

Sputnik Notebook can load the C leaves as a prepared native dependency while
evaluating the public Sputnik API in its isolated worker. The sibling
[`SQLite / Data Table example`](../sputnik-notebook/docs/engineering/notebook-sqlite-example.md)
includes preparation, a read-only external database connection, bound queries
and SQL pagination. No database contents are copied into the notebook.

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

Connection pool (`Pool` / `PoolLease`):

- `pool` and `memory_pool`, with block-scoped lifecycle or handle-returning
  forms; lazy growth from `min_size:` to `max_size:`
- scoped `checkout` / `with_connection` and manual `acquire`; finite default or
  per-call checkout timeouts with `PoolTimeoutError`
- safe capture by `task.spawn`, notification-driven checkout waiting through a
  buffered `Channel`, and exclusive lease ownership of every physical SQLite
  connection
- scoped `checkout` / `transaction` installs a non-inheritable logical
  task-local connection context that survives suspension and worker migration
- nested Pool/ORM calls automatically reuse the current task's checkout or
  transaction, while a `task.spawn` child acquires its own lease
- the common `Database` executor surface (`query`, `execute`, CRUD helpers,
  `transaction`, and block-scoped `prepare`) directly on `Pool`
- `stats`, `prune!`, `disconnect!`, `drain!`, idle timeout, maximum lifetime,
  startup pragmas, busy timeout, and pool-wide query instrumentation
- release hygiene: open statements are finalized, active transactions are
  rolled back, unhealthy/closed/expired connections are discarded, and release
  is idempotent

Query execution has a package-neutral instrumentation boundary. Install any
object implementing `instrument(execution, &execute)` with
`db.instrument_queries!(instrumenter)`. The callback receives a
`sqlite3.SqlExecution` containing `operation`, final prepared `sql`, and the
original `params`; it must invoke the supplied block and return its result.
High-level statement helpers and transaction commands pass through this
boundary, allowing logging, tracing, metrics, and OpenTelemetry spans without
coupling them to this package. The same method exists on `Pool`; every checked-out
`Database` inherits the current instrumenter.

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
`TransactionError`, `Pool*Error`, `Json*Error`), with SQLite result-code mapping.
Rescue by the registered name, e.g. `rescue Sqlite3.ConstraintError |e|:`.

Safety: `ATTACH` / `DETACH` / `VACUUM INTO` are rejected by the native layer
(design §11, §15); direct-execution helpers reject trailing SQL after the first
statement; `exec` is the trusted multi-statement path.

The core self-test ([`test/selftest.s`](test/selftest.s)) exercises 35
end-to-end behaviours. [`test/pool_selftest.s`](test/pool_selftest.s) adds
concurrent tasks, timeout, scoped leases, cleanup, and maintenance checks;
[`test/orm_pool_selftest.s`](test/orm_pool_selftest.s) verifies direct
`orm` integration and task-local transactional routing.

## Pool API and concurrency model

The scoped form is the default:

```sputnik
sqlite3.pool("data/app.db",
  min_size: 1,
  max_size: 10,
  checkout_timeout: 2.0,
  idle_timeout: 60.0,
  max_lifetime: 30.minutes,
  busy_timeout: 2.0,
  pragmas: {foreign_keys: true, journal_mode: :wal}
) |pool|:
  pool.checkout |db|:
    db.query("select id, email from users")

  pool.transaction(mode: :immediate):
    # Calls through pool resolve to this logical task's transaction.
    pool.execute("insert into audit(message) values (?)", params: ["created"])
```

`checkout_timeout: null` means unlimited waiting. Duration options accept
numeric seconds or `TimePeriod`; `idle_timeout: null` and `max_lifetime: null`
disable their respective retirement rule. `min_size` is warmed on construction
and retained against idle pruning; a connection discarded after an error is
recreated lazily on demand.

Manual leases are available for framework internals, but should stay within the
task that acquired them:

```sputnik
lease = pool.acquire(timeout: 0.5)
try:
  lease.db().scalar("select 1")
ensure:
  lease.release!()
```

`Pool` is the shareable boundary. `Database`, `Statement`, and `PoolLease` must
not be sent to sibling tasks. Each Pool owns a non-inheritable `task.local`
slot: a scoped checkout installs its connection there, and the binding follows
the logical task across suspension and worker migration. Nested calls through
the Pool reuse that connection. A `task.spawn` child deliberately starts
without the binding and acquires a separate lease, so one SQLite connection is
not used concurrently by parent and child. Scoped blocks are no longer forced
through `task.sync`, so a parked continuation may resume on another worker.
The current direct-native implementation of `task.sleep` can still block its
worker; making that path park cooperatively is a separate runtime improvement
from task-local connection routing.

The vendored SQLite build uses serialized `SQLITE_THREADSAFE=1`, and PoolCore
enforces exclusive lease ownership and generation checks. Holding an SQL
transaction open across unrelated network waits is still discouraged because
it retains a connection and database locks, not because of native-thread
affinity. Feature discovery reports `pool_affinity: :lease` and
`pool_context: :task_local`.

For in-memory tests, use `memory_pool`; plain `:memory:` creates one isolated
database per connection and is therefore rejected for `max_size > 1`:

```sputnik
sqlite3.memory_pool(name: "request_tests", max_size: 4) |pool|:
  # all pooled connections see the same named in-memory database
  ...
```

### `orm` / web-framework boundary

`Pool` intentionally implements the same small executor surface as `Database`,
so the existing adapter can consume it directly:

```sputnik
from orm.sqlite3 import adapter as sqlite_adapter

User.bind!(sqlite_adapter(pool)).or_raise

pool.transaction:
  # User remains bound to pool; this operation resolves to the current tx.
  User.create(email: "ada@example.test").or_raise
```

A future web framework only needs request middleware around
`pool.with_connection |db|: ...`; models may stay bound to
`sqlite_adapter(pool)`. Calls made by that logical request task reuse `db`, and
explicit transactions automatically route the same adapter through their
transaction connection. The yielded `db` / `tx` remains available for code
that prefers an explicit executor.

## Deferred (not yet implemented)

These parts of the design are intentionally left for follow-up work and are
called out here for honesty:

- **JSON/JSONB query-builder wrappers** `json()` / `jsonb()` and
  `to_json` / `to_jsonb` (design §9.4). The capability *probes* are implemented;
  the value wrappers are not.

## Toolchain requirements

Building this package exercises language features that were fixed/added in the
Sputnik toolchain alongside it (logical `task.local` context, forward references
between module functions, namespace-qualified calls `module.func()`,
cross-module closure capture preservation, `self` as a first-class value, and
the `macro.v1` string-tag macro profile). It requires an Sputnik toolchain that
includes those fixes.

## Layout

```
sputnik.build.yaml        package manifest (module + native extension)
src/sqlite3.s          the public API, in Sputnik
native/sqlite3_ext.c    native leaves over the sputnik_ext ABI
native/sqlite3.c/.h     vendored SQLite amalgamation (3.51.0, public domain)
test/selftest.s        end-to-end conformance test (returns 35)
test/selftest.build.yaml  build manifest for the self-test
test/pool_selftest.s   pool concurrency/lifecycle test (returns 18)
test/orm_pool_selftest.s  orm pool integration test (returns 4)
examples/basic.s       a small usage example
examples/pool.s        concurrent pool + scoped transaction example
```

## License

The package code (`src/`, `native/sqlite3_ext.c`, tests, examples) is released
into the public domain (see [LICENSE](LICENSE)). The vendored SQLite amalgamation
is itself public domain (https://www.sqlite.org/copyright.html).

package sqlite3

import task
from sync import Mutex

# sqlite3 — a native-only Sputnik package for SQLite databases.
#
# Architecture: the sputnik_ext ABI exposes only null/bool/int/float/str/bytes/
# list + foreign handles, so the C leaves (native/sqlite3_ext.c) stay low-level
# (SQL as Str, binds as a flat List, rows as Lists). Everything a user touches —
# name-indifferent row Maps, named parameters, keyword arguments, transactions,
# the convenience SQL builders, pooling policy, and the typed error surface —
# is built here in Sputnik over small private native handles.

export open, connect, memory, pool, memory_pool
export version, source_id, libversion_number, compile_options, features
export fragment, ident, quote_identifier
export Database, Statement, Pool, PoolLease, SqlFragment, SqlIdent, SqlExecution
export Error, OpenError, PrepareError, BindError, StepError, RangeError
export ConstraintError, BusyError, LockedError, ReadOnlyError, InterruptError
export CorruptError, MisuseError, TransactionError, JsonError
export JsonUnavailableError, JsonbUnavailableError
export PoolError, PoolClosedError, PoolTimeoutError, PoolLeaseError
export macro sql

class Error < NativeError
class OpenError < Error
class PrepareError < Error
class BindError < Error
class StepError < Error
class RangeError < BindError
class ConstraintError < StepError
class BusyError < StepError
class LockedError < StepError
class ReadOnlyError < StepError
class InterruptError < StepError
class CorruptError < StepError
class MisuseError < Error
class TransactionError < Error
class PoolError < Error
class PoolClosedError < PoolError
class PoolTimeoutError < PoolError
class PoolLeaseError < PoolError
class JsonError < Error
class JsonUnavailableError < JsonError
class JsonbUnavailableError < JsonError

# ---------------------------------------------------------------- native leaves

native def _libversion() -> Str from "amsq_libversion"
native def _sourceid() -> Str from "amsq_sourceid"
native def _libversion_number() -> Int from "amsq_libversion_number"
native def _compile_options() -> List from "amsq_compile_options"

# A raw connection handle. Never handed to users directly; wrapped by Database.
native class Conn from "sqlite3.Conn" owned:
  def init(path_text as Str, flags as Int, busy_ms as Int) from "amsq_conn_open"
  def _close() from "amsq_conn_close"
  def destroy!() from "amsq_conn_free"
  def _closed?() -> Bool from "amsq_conn_closed"
  def _filename(schema as Str) -> Str from "amsq_conn_filename"
  def _readonly?(schema as Str) -> Bool from "amsq_conn_readonly"
  def _in_transaction?() -> Bool from "amsq_conn_in_transaction"
  def _changes() -> Int from "amsq_conn_changes"
  def _total_changes() -> Int from "amsq_conn_total_changes"
  def _last_insert_rowid() -> Int from "amsq_conn_last_insert_rowid"
  def _interrupt() from "amsq_conn_interrupt"
  def _busy_timeout(ms as Int) from "amsq_conn_busy_timeout"
  def _exec(sql as Str) from "amsq_conn_exec"
  def _prepare(sql as Str) from "amsq_conn_prepare"
  def _probe(sql as Str) -> Bool from "amsq_conn_probe"
  def _backup_into(destination, timeout_ms as Int) from "amsq_conn_backup" blocking

# A raw prepared-statement handle. Produced by Conn#_prepare, wrapped by
# Statement; never constructed directly, so it declares no init.
native class Stmt from "sqlite3.Stmt" owned:
  def destroy!() from "amsq_stmt_free"
  def _finalize() from "amsq_stmt_finalize"
  def _closed?() -> Bool from "amsq_stmt_closed"
  def _sql() -> Str from "amsq_stmt_sql"
  def _column_count() -> Int from "amsq_stmt_column_count"
  def _column_names() -> List from "amsq_stmt_column_names"
  def _column_meta() -> List from "amsq_stmt_column_meta"
  def _parameter_count() -> Int from "amsq_stmt_parameter_count"
  def _parameter_names() -> List from "amsq_stmt_parameter_names"
  def _readonly?() -> Bool from "amsq_stmt_readonly"
  def _busy?() -> Bool from "amsq_stmt_busy"
  def _reset!() from "amsq_stmt_reset"
  def _clear_bindings!() from "amsq_stmt_clear_bindings"
  def _bind(values as List) from "amsq_stmt_bind"
  def _step!() from "amsq_stmt_step"
  def _rows() -> List from "amsq_stmt_rows"

# Thread-safe shared state for a pool. It is collected because reclamation is
# context-free and refcounted against outstanding lease handles.
native class PoolCore from "sqlite3.PoolCore" collected:
  def init(path_text as Str, flags as Int, busy_ms as Int, min_size as Int, max_size as Int, idle_timeout_ns as Int, max_lifetime_ns as Int) from "amsq_pool_core_new"
  def destroy!() from "amsq_pool_core_free"
  def _try_acquire() from "amsq_pool_try_acquire"
  def _acquire_wait(timeout_ns as Int) from "amsq_pool_acquire_wait" blocking
  # Returns -1 for an already-finished lease, otherwise the number of waiters
  # observed after returning/discarding the connection.
  def _release(conn, discard as Bool) -> Int from "amsq_pool_release"
  def _lease_released(conn) -> Bool from "amsq_pool_lease_released"
  def _stats() -> List from "amsq_pool_stats"
  def _prune() -> Int from "amsq_pool_prune"
  def _disconnect() -> Int from "amsq_pool_disconnect"
  def _close() from "amsq_pool_close"
  def _closed?() -> Bool from "amsq_pool_closed"

# A generation-checked view of a connection owned by PoolCore. Reclaiming a
# forgotten manual lease safely rolls it back and returns it to the pool.
native class LeaseConn from "sqlite3.LeaseConn" collected:
  def destroy!() from "amsq_lease_conn_free"
  def _close() from "amsq_conn_close"
  def _closed?() -> Bool from "amsq_conn_closed"
  def _filename(schema as Str) -> Str from "amsq_conn_filename"
  def _readonly?(schema as Str) -> Bool from "amsq_conn_readonly"
  def _in_transaction?() -> Bool from "amsq_conn_in_transaction"
  def _changes() -> Int from "amsq_conn_changes"
  def _total_changes() -> Int from "amsq_conn_total_changes"
  def _last_insert_rowid() -> Int from "amsq_conn_last_insert_rowid"
  def _interrupt() from "amsq_conn_interrupt"
  def _busy_timeout(ms as Int) from "amsq_conn_busy_timeout"
  def _exec(sql as Str) from "amsq_conn_exec"
  def _prepare(sql as Str) from "amsq_conn_prepare"
  def _probe(sql as Str) -> Bool from "amsq_conn_probe"
  def _backup_into(destination, timeout_ms as Int) from "amsq_conn_backup" blocking

# ---------------------------------------------------------- typed SQL values

# A trusted raw SQL fragment plus its positional bind parameters.
class SqlFragment:
  def init(@fragment_text, @fragment_params)
  def text():
    @fragment_text
  def params():
    @fragment_params

# A validated (already-quoted) SQL identifier marker.
class SqlIdent:
  def init(@ident_sql)
  def sql():
    @ident_sql

# The stable boundary presented to query instrumenters. Instrumenters receive
# one of these and the actual execution block through `instrument`.
class SqlExecution:
  attr operation
  attr sql
  attr params

  def init(@operation, @sql, @params)

# Internal duck-protocol declaration for the optional instrumentation boundary.
# It gives the native backend a stable user-method dispatch shape even when a
# consumer executable installs no instrumenter of its own.
class _QueryInstrumenterProtocol:
  def instrument(execution, &execute):
    execute()

# ------------------------------------------------------------- module functions

def version():
  _libversion()

def source_id():
  _sourceid()

def libversion_number():
  _libversion_number()

def compile_options():
  _compile_options()

def features():
  _feature_map(null)

def fragment(text as Str, params = []):
  SqlFragment(text, params)

string_tag macro def sql(t as Ast.StringTemplate):
  query = ""
  params = []
  t.parts.each |part|:
    if part.kind == "AstStringText":
      query = query + part.value
    elif part.kind == "AstStringExpr":
      query = query + "?"
      params.push!(part.expr)
    else:
      raise ValueError("unsupported SQL template part: " + part.kind)
  return quote:
    sqlite3.fragment(#{Ast.lift(query)}, #{Ast.node("AstListLiteral", {elements: params})})

def ident(name):
  SqlIdent(_render_ident(name))

def quote_identifier(name):
  _render_ident(name)

def open(path as (Str | fs.Path), mode: :create, uri: false, busy_timeout: null, pragmas: {}, &blk):
  flags = _open_flags(mode, uri)
  busy_ms = _busy_ms(busy_timeout)
  conn = Conn(_path_text(path), flags, busy_ms)
  db = Database(conn)
  db._apply_pragmas(pragmas)
  return db unless blk
  try:
    blk(db)
  ensure:
    db.close!()

def connect(path as (Str | fs.Path), mode: :create, uri: false, busy_timeout: null, pragmas: {}, &blk):
  db = open(path, mode: mode, uri: uri, busy_timeout: busy_timeout, pragmas: pragmas)
  return db unless blk
  try:
    blk(db)
  ensure:
    db.close!()

def memory(name: null, shared: false, busy_timeout: null, pragmas: {}, &blk):
  busy_ms = _busy_ms(busy_timeout)
  path = ":memory:"
  flags = 6
  if name:
    path = "file:" + _text_of(name) + "?mode=memory"
    if shared:
      path = path + "&cache=shared"
    flags = 70
  conn = Conn(path, flags, busy_ms)
  db = Database(conn)
  db._apply_pragmas(pragmas)
  return db unless blk
  try:
    blk(db)
  ensure:
    db.close!()

def pool(path as (Str | fs.Path), mode: :create, uri: false, min_size: 0, max_size: 5, checkout_timeout: 5.0, idle_timeout: 60.0, max_lifetime: null, busy_timeout: null, pragmas: {}, &blk):
  _validate_pool_sizes(min_size, max_size)
  flags = _open_flags(mode, uri)
  path_text = _path_text(path)
  if path_text == ":memory:" and max_size > 1:
    raise ArgumentError("a multi-connection pool cannot use isolated :memory: databases; use sqlite3.memory_pool")
  core = PoolCore(
    path_text,
    flags,
    _busy_ms(busy_timeout),
    min_size,
    max_size,
    _pool_duration_ns(idle_timeout, "idle_timeout", true),
    _pool_duration_ns(max_lifetime, "max_lifetime", true)
  )
  p = Pool(core,
    checkout_timeout_ns: _pool_duration_ns(checkout_timeout, "checkout_timeout", true),
    pragmas: pragmas,
    min_size: min_size)
  try:
    p._warm!()
  rescue |e|:
    p.close!()
    raise e
  return p unless blk
  try:
    blk(p)
  ensure:
    p.close!()

# Multiple `:memory:` connections are separate SQLite databases. This helper
# deliberately chooses a named shared-cache URI so a real pool sees one DB.
def memory_pool(name: "sputnik_pool", min_size: 1, max_size: 5, checkout_timeout: 5.0, idle_timeout: 60.0, max_lifetime: null, busy_timeout: null, pragmas: {}, &blk):
  name_text = _text_of(name)
  raise ArgumentError("memory pool name must be a safe identifier") unless _valid_ident(name_text)
  path = "file:" + name_text + "?mode=memory&cache=shared"
  p = pool(path,
    uri: true,
    min_size: min_size,
    max_size: max_size,
    checkout_timeout: checkout_timeout,
    idle_timeout: idle_timeout,
    max_lifetime: max_lifetime,
    busy_timeout: busy_timeout,
    pragmas: pragmas)
  return p unless blk
  try:
    blk(p)
  ensure:
    p.close!()

# ---------------------------------------------------------------------- Pool

class PoolLease:
  def init(@core, @raw, @database)

  def db():
    raise PoolLeaseError("the connection lease has been released") if released?()
    @database

  def _raw():
    @raw

  def release!():
    @core._release(@raw, false)
    null

  def discard!():
    @core._release(@raw, true)
    null

  def released?():
    @core._lease_released(@raw)

class Pool:
  def init(@core, checkout_timeout_ns:, pragmas:, min_size:):
    @checkout_timeout_ns = checkout_timeout_ns
    @pragmas = pragmas
    @min_size = min_size
    # A scoped checkout belongs to the logical Sputnik task, not to a scheduler
    # worker. Exclusive leases must never be inherited by task.spawn children.
    @current_connection = task.local(inherit: false)
    @state_mutex = Mutex.new()
    @query_instrumenter = null

  # lifecycle -----------------------------------------------------------
  def close!():
    @core._close()
    null
  def destroy!():
    close!()
  def closed?():
    @core._closed?()

  # instrumentation -----------------------------------------------------
  def instrument_queries!(instrumenter):
    @state_mutex.synchronize:
      @query_instrumenter = instrumenter
    self

  def query_instrumenter():
    @state_mutex.synchronize:
      @query_instrumenter

  # checkout ------------------------------------------------------------
  def acquire(timeout: null):
    timeout_ns = if timeout then _pool_duration_ns(timeout, "checkout timeout", false) else @checkout_timeout_ns
    result = @core._try_acquire()
    return _lease_from_result(result) if result
    if timeout_ns == 0:
      raise PoolTimeoutError("timed out waiting for a database connection")
    _lease_from_result(@core._acquire_wait(timeout_ns))

  def checkout(timeout: null, &blk):
    raise ArgumentError("checkout requires a block; use acquire for a manual lease") unless blk
    if @current_connection.bound?():
      return blk(@current_connection.get())
    lease = acquire(timeout: timeout)
    db = lease.db()
    try:
      @current_connection.with(db):
        blk(db)
    ensure:
      lease.release!()

  def with_connection(timeout: null, &blk):
    checkout(timeout: timeout) |db|:
      blk(db)

  # Pool is also a small connection-provider/executor. Adapters can bind to it
  # once; calls inside checkout/transaction reuse this task's current lease.
  def exec(sql):
    _with_executor_connection() |db|: db.exec(sql)
  def execute(sql, params: null):
    _with_executor_connection() |db|: db.execute(sql, params: params)
  def execute_many(sql, params):
    _with_executor_connection() |db|: db.execute_many(sql, params)
  def query(sql, params: null):
    _with_executor_connection() |db|: db.query(sql, params: params)
  def query_one(sql, params: null, default: null):
    _with_executor_connection() |db|: db.query_one(sql, params: params, default: default)
  def scalar(sql, params: null, default: null):
    _with_executor_connection() |db|: db.scalar(sql, params: params, default: default)
  def query_arrays(sql, params: null):
    _with_executor_connection() |db|: db.query_arrays(sql, params: params)
  def each(sql, params: null, &blk):
    raise ArgumentError("each requires a block") unless blk
    _with_executor_connection() |db|:
      db.each(sql, params: params) |row|:
        blk(row)
  def each_array(sql, params: null, &blk):
    raise ArgumentError("each_array requires a block") unless blk
    _with_executor_connection() |db|:
      db.each_array(sql, params: params) |row|:
        blk(row)
  def prepare(sql, &blk):
    raise PoolLeaseError("Pool#prepare requires a block so the statement cannot outlive its lease") unless blk
    _with_executor_connection() |db|:
      db.prepare(sql) |statement|:
        blk(statement)

  def transaction(mode: :deferred, &blk):
    raise ArgumentError("transaction requires a block") unless blk
    _with_executor_connection() |db|:
      db.transaction(mode: mode) |tx|:
        @current_connection.with(tx):
          blk(tx)

  # convenience query surface used by sputnik-orm -------------------------
  def insert(table, columns:, values:, returning: null):
    _with_executor_connection() |db|: db.insert(table, columns: columns, values: values, returning: returning)
  def insert_or_ignore(table, columns:, values:, returning: null):
    _with_executor_connection() |db|: db.insert_or_ignore(table, columns: columns, values: values, returning: returning)
  def insert_or_replace(table, columns:, values:, returning: null):
    _with_executor_connection() |db|: db.insert_or_replace(table, columns: columns, values: values, returning: returning)
  def upsert(table, columns:, values:, returning: null):
    _with_executor_connection() |db|: db.upsert(table, columns: columns, values: values, returning: returning)
  def update(table, set:, where: null, where_not: null, returning: null):
    _with_executor_connection() |db|: db.update(table, set: set, where: where, where_not: where_not, returning: returning)
  def delete(table, where: null, where_not: null, returning: null):
    _with_executor_connection() |db|: db.delete(table, where: where, where_not: where_not, returning: returning)
  def select(table, columns: :all, where: null, where_not: null, group_by: null, having: null, order: null, limit: null, offset: null):
    _with_executor_connection() |db|: db.select(table, columns: columns, where: where, where_not: where_not, group_by: group_by, having: having, order: order, limit: limit, offset: offset)
  def get(table, columns: :all, where: null, where_not: null, group_by: null, having: null, order: null):
    _with_executor_connection() |db|: db.get(table, columns: columns, where: where, where_not: where_not, group_by: group_by, having: having, order: order)

  # maintenance / metadata ----------------------------------------------
  def features():
    _feature_map(null)
  def json_available?():
    _with_executor_connection() |db|: db.json_available?()
  def jsonb_available?():
    _with_executor_connection() |db|: db.jsonb_available?()
  def jsonb_each_available?():
    _with_executor_connection() |db|: db.jsonb_each_available?()
  def jsonb_tree_available?():
    _with_executor_connection() |db|: db.jsonb_tree_available?()
  def readonly?(schema: :main):
    _with_executor_connection() |db|: db.readonly?(schema: schema)
  def filename(schema: :main):
    _with_executor_connection() |db|: db.filename(schema: schema)

  def stats():
    values = @core._stats()
    {
      min_size: values[0],
      max_size: values[1],
      open: values[2],
      idle: values[3],
      leased: values[4],
      waiting: values[5],
      closed: values[6],
      generation: values[7]
    }

  def prune!():
    {closed: @core._prune()}

  def disconnect!():
    {closed: @core._disconnect()}

  def drain!(timeout: null):
    close!()
    timeout_ns = _pool_duration_ns(timeout, "drain timeout", true)
    started = Time.monotonic
    while stats()[:leased] > 0:
      if timeout_ns >= 0 and (Time.monotonic - started).total_nanoseconds >= timeout_ns:
        raise PoolTimeoutError("timed out draining leased database connections")
      task.sleep(0.001)
    null

  def _with_executor_connection(&blk):
    if @current_connection.bound?():
      return blk(@current_connection.get())
    checkout() |db|:
      blk(db)

  def _warm!():
    return self if @min_size == 0
    leases = []
    try:
      while leases.count < @min_size:
        result = @core._try_acquire()
        raise PoolError("could not warm the configured minimum pool size") unless result
        leases.push!(_lease_from_result(result))
    ensure:
      leases.each |lease|:
        lease.release!()
    self

  def _lease_from_result(result):
    raw = result[0]
    lease = PoolLease(@core, raw, _database_for(raw))
    if result[1]:
      try:
        lease.db()._apply_pragmas(@pragmas)
      rescue |e|:
        lease.discard!()
        raise e
    lease

  def _database_for(raw):
    db = Database(raw, pooled: true)
    instrumenter = query_instrumenter()
    db.instrument_queries!(instrumenter) if instrumenter
    db

# ------------------------------------------------------------------ Database

class Database:
  def init(@conn, pooled: false):
    @pooled = pooled
    @savepoint_counter = 0
    @query_instrumenter = null

  def instrument_queries!(instrumenter):
    @query_instrumenter = instrumenter
    self

  def query_instrumenter():
    @query_instrumenter

  def _instrument_query(operation, sql, params, &execute):
    return execute() unless @query_instrumenter
    @query_instrumenter.instrument(SqlExecution(operation, sql, params), &execute)

  def _exec_sql(sql):
    _instrument_query(:exec, sql, null):
      @conn._exec(sql)

  def _with_statement(operation, sql, params, &execute):
    _instrument_query(operation, sql, params):
      prepare(sql) |statement|:
        execute(statement)

  # lifecycle -------------------------------------------------------------
  def close!():
    @conn._close()
    null
  def destroy!():
    if @pooled:
      @conn._close()
    else:
      @conn.destroy!()
    null
  def closed?():
    @conn._closed?

  # metadata --------------------------------------------------------------
  def filename(schema: :main):
    @conn._filename(_text_of(schema))
  def readonly?(schema: :main):
    @conn._readonly?(_text_of(schema))
  def in_transaction?():
    @conn._in_transaction?
  def changes():
    @conn._changes()
  def total_changes():
    @conn._total_changes()
  def last_insert_rowid():
    @conn._last_insert_rowid()
  def busy_timeout!(timeout):
    @conn._busy_timeout(_busy_ms(timeout))
    self
  def interrupt!():
    @conn._interrupt()
    null

  # Online SQLite backup into a separately opened destination connection.
  # Destination must not be in a transaction; timeout includes BUSY retries.
  def backup_into(destination, timeout: 30.0):
    @conn._backup_into(destination._backup_connection(), _busy_ms(timeout))
    destination

  def _backup_connection(): @conn

  # direct execution ------------------------------------------------------
  def exec(sql):
    text = case sql:
      when Str:
        sql
      when SqlFragment:
        if sql.params.count > 0:
          raise ArgumentError("exec: a fragment passed to exec must not carry parameters")
        sql.text
      else:
        raise ArgumentError("exec expects a Str or parameterless fragment")
    _exec_sql(text)
    _command_result(self)

  def prepare(sql, &blk):
    handle = @conn._prepare(_prepare_text(sql))
    st = Statement(handle, self)
    return st unless blk
    try:
      blk(st)
    ensure:
      st.close!()

  def execute(sql, params: null):
    parts = _sql_parts(sql, params)
    _with_statement(:execute, parts[0], parts[1]) |statement|:
      statement._execute(parts[1])

  def execute_many(sql, params):
    text = _prepare_text(sql)
    _with_statement(:execute_many, text, params) |statement|:
      total = 0
      last = 0
      params.each |entry|:
        result = statement._execute(entry)
        total = total + result[:affected_rows]
        last = result[:last_insert_id]
      {affected_rows: total, changes: total, total_changes: @conn._total_changes(), last_insert_id: last, last_insert_rowid: last}

  def query(sql, params: null):
    parts = _sql_parts(sql, params)
    _with_statement(:query, parts[0], parts[1]) |statement|:
      statement._query(parts[1])

  def query_one(sql, params: null, default: null):
    parts = _sql_parts(sql, params)
    _with_statement(:query, parts[0], parts[1]) |statement|:
      statement._query_one(parts[1], default)

  def scalar(sql, params: null, default: null):
    parts = _sql_parts(sql, params)
    _with_statement(:query, parts[0], parts[1]) |statement|:
      statement._scalar(parts[1], default)

  def query_arrays(sql, params: null):
    parts = _sql_parts(sql, params)
    _with_statement(:query, parts[0], parts[1]) |statement|:
      statement._query_arrays(parts[1])

  def each(sql, params: null, &blk):
    raise ArgumentError("each requires a block") unless blk
    parts = _sql_parts(sql, params)
    _with_statement(:query, parts[0], parts[1]) |statement|:
      statement._each(parts[1], &blk)

  def each_array(sql, params: null, &blk):
    raise ArgumentError("each_array requires a block") unless blk
    parts = _sql_parts(sql, params)
    _with_statement(:query, parts[0], parts[1]) |statement|:
      statement._each_array(parts[1], &blk)

  # transactions ----------------------------------------------------------
  def begin!(mode: :deferred):
    raise TransactionError("already in a transaction; use transaction or savepoint for nesting") if @conn._in_transaction?
    _exec_sql(_begin_sql(mode))
    self
  def commit!():
    _exec_sql("COMMIT")
    self
  def rollback!():
    _exec_sql("ROLLBACK")
    self

  def transaction(mode: :deferred, &blk):
    raise ArgumentError("transaction requires a block") unless blk
    if @conn._in_transaction?:
      if mode != :deferred:
        raise TransactionError("a nested transaction must use mode: :deferred (savepoints cannot upgrade the outer mode)")
      return savepoint(&blk)
    _exec_sql(_begin_sql(mode))
    committed = false
    try:
      result = blk(self)
      _exec_sql("COMMIT")
      committed = true
      result
    ensure:
      if not committed:
        _safe_exec("ROLLBACK")

  def savepoint(name: null, &blk):
    raise ArgumentError("savepoint requires a block") unless blk
    sp = _savepoint_name(name)
    quoted = _quote_one(sp)
    _exec_sql("SAVEPOINT " + quoted)
    released = false
    try:
      result = blk(self)
      _exec_sql("RELEASE " + quoted)
      released = true
      result
    ensure:
      if not released:
        _safe_exec("ROLLBACK TO " + quoted)
        _safe_exec("RELEASE " + quoted)

  def _savepoint_name(name):
    unless name:
      @savepoint_counter = @savepoint_counter + 1
      return "sputnik_sp_" + @savepoint_counter.to_str
    sp = _text_of(name)
    raise ArgumentError("savepoint name must be a safe SQL identifier: " + sp) unless _valid_ident(sp)
    sp

  def _safe_exec(sql):
    try:
      _exec_sql(sql)
    rescue Error |e|:
      null

  # pragmas ---------------------------------------------------------------
  def pragma(name):
    scalar("PRAGMA " + _safe_ident(name))
  def pragma!(name, value):
    exec("PRAGMA " + _safe_ident(name) + " = " + _pragma_value_sql(value))
    self
  def _apply_pragmas(pragmas):
    return null unless pragmas
    pragmas.each |name, value|:
      pragma!(name, value)
    null

  # feature discovery -----------------------------------------------------
  def features():
    _feature_map(self)
  def json_available?():
    @conn._probe("SELECT json('1')")
  def jsonb_available?():
    @conn._probe("SELECT jsonb('1')")
  def jsonb_each_available?():
    @conn._probe("SELECT 1 FROM jsonb_each('[1]')")
  def jsonb_tree_available?():
    @conn._probe("SELECT 1 FROM jsonb_tree('[1]')")

  # convenience: insert ---------------------------------------------------
  def insert(table, columns:, values:, returning: null):
    _insert_core("INSERT", table, columns, values, returning)
  def insert_or_ignore(table, columns:, values:, returning: null):
    _insert_core("INSERT OR IGNORE", table, columns, values, returning)
  def insert_or_replace(table, columns:, values:, returning: null):
    _insert_core("INSERT OR REPLACE", table, columns, values, returning)
  def upsert(table, columns:, values:, returning: null):
    _insert_core("INSERT OR REPLACE", table, columns, values, returning)

  def _insert_core(verb, table, columns, values, returning):
    cols = _as_list(columns)
    col_sql = cols.map: _render_ident(_1)
    col_names = cols.map: _ident_key(_1)
    binds = []
    row_frags = _rows_of(values).map |row|:
      _row_placeholders(_row_values(row, col_names), binds)
    sql = verb + " INTO " + _render_ident(table) + " (" + col_sql.join(", ") + ") VALUES " + row_frags.join(", ")
    ret = _returning_sql(returning)
    if ret:
      return _with_statement(:query, sql + " RETURNING " + ret, binds) |statement|:
        statement._query(binds)
    else:
      _with_statement(:execute, sql, binds) |statement|:
        statement._execute(binds)

  # convenience: update / delete -----------------------------------------
  def update(table, set:, where: null, where_not: null, returning: null):
    binds = []
    assigns = _require_map(set, "set:").map |k, v|:
      binds.push!(v)
      _render_ident(k) + " = ?"
    raise ArgumentError("update: set: must not be empty") if assigns.count == 0
    sql = "UPDATE " + _render_ident(table) + " SET " + assigns.join(", ")
    wc = _where_clause(where, where_not, binds)
    if wc:
      sql = sql + " WHERE " + wc
    _write_with_returning(sql, binds, returning)

  def delete(table, where: null, where_not: null, returning: null):
    binds = []
    sql = "DELETE FROM " + _render_ident(table)
    wc = _where_clause(where, where_not, binds)
    if wc:
      sql = sql + " WHERE " + wc
    _write_with_returning(sql, binds, returning)

  def _write_with_returning(sql, binds, returning):
    ret = _returning_sql(returning)
    if ret:
      return _with_statement(:query, sql + " RETURNING " + ret, binds) |statement|:
        statement._query(binds)
    else:
      _with_statement(:execute, sql, binds) |statement|:
        statement._execute(binds)

  # convenience: select / get --------------------------------------------
  def select(table, columns: :all, where: null, where_not: null, group_by: null, having: null, order: null, limit: null, offset: null):
    binds = []
    sql = _select_sql(table, columns, where, where_not, group_by, having, order, limit, offset, binds)
    _with_statement(:query, sql, binds) |statement|:
      statement._query(binds)

  def get(table, columns: :all, where: null, where_not: null, group_by: null, having: null, order: null):
    binds = []
    sql = _select_sql(table, columns, where, where_not, group_by, having, order, 1, null, binds)
    _with_statement(:query, sql, binds) |statement|:
      statement._query_one(binds, null)

# ------------------------------------------------------------------ Statement

class Statement:
  def init(@stmt, @db)

  # lifecycle / metadata --------------------------------------------------
  def close!():
    @stmt._finalize()
    null
  def destroy!():
    @stmt._finalize()
    null
  def closed?():
    @stmt._closed?
  def sql():
    @stmt._sql()
  def column_count():
    @stmt._column_count()
  def column_names():
    @stmt._column_names()
  def columns():
    @stmt._column_meta.map |m|:
      {name: m[0], database: m[1], table: m[2], origin_name: m[3], declared_type: m[4]}
  def parameter_count():
    @stmt._parameter_count()
  def parameter_names():
    @stmt._parameter_names()
  def readonly?():
    @stmt._readonly?
  def busy?():
    @stmt._busy?

  # low-level stepping ----------------------------------------------------
  def bind!(params = null):
    @stmt._clear_bindings!()
    @stmt._bind(_positional_params(@stmt, params))
    self
  def reset!():
    @stmt._reset!()
    self
  def clear_bindings!():
    @stmt._clear_bindings!()
    self
  def step():
    names = @stmt._column_names()
    row = @stmt._step!()
    if row: _zip_row(names, row)

  def step_array():
    @stmt._step!()

  # high-level helpers (clear + bind + run + reset) -----------------------
  def _prime(params):
    @stmt._clear_bindings!()
    @stmt._bind(_positional_params(@stmt, params))

  def execute(params: null):
    @db._instrument_query(:execute, sql, params):
      _execute(params)

  def _execute(params):
    _prime(params)
    first = @stmt._step!()
    if first:
      @stmt._reset!()
      raise StepError("execute: statement returned rows; use query, query_one, or scalar")
    @stmt._reset!()
    _command_result(@db)

  def query(params: null):
    @db._instrument_query(:query, sql, params):
      _query(params)

  def _query(params):
    _prime(params)
    names = @stmt._column_names()
    rows = @stmt._rows()
    @stmt._reset!()
    rows.map: _zip_row(names, _1)

  def query_one(params: null, default: null):
    @db._instrument_query(:query, sql, params):
      _query_one(params, default)

  def _query_one(params, default):
    _prime(params)
    names = @stmt._column_names()
    row = @stmt._step!()
    @stmt._reset!()
    if row:
      _zip_row(names, row)
    else:
      default

  def scalar(params: null, default: null):
    @db._instrument_query(:query, sql, params):
      _scalar(params, default)

  def _scalar(params, default):
    _prime(params)
    row = @stmt._step!()
    @stmt._reset!()
    if row:
      row[0]
    else:
      default

  def query_arrays(params: null):
    @db._instrument_query(:query, sql, params):
      _query_arrays(params)

  def _query_arrays(params):
    _prime(params)
    cols = @stmt._column_names()
    rows = @stmt._rows()
    @stmt._reset!()
    {columns: cols, rows: rows}

  def each(params: null, &blk):
    raise ArgumentError("each requires a block") unless blk
    @db._instrument_query(:query, sql, params):
      _each(params, &blk)

  def _each(params, &blk):
    _prime(params)
    names = @stmt._column_names()
    count = 0
    while row = @stmt._step!():
      blk(_zip_row(names, row))
      count += 1
    @stmt._reset!()
    count

  def each_array(params: null, &blk):
    raise ArgumentError("each_array requires a block") unless blk
    @db._instrument_query(:query, sql, params):
      _each_array(params, &blk)

  def _each_array(params, &blk):
    _prime(params)
    count = 0
    while row = @stmt._step!():
      blk(row)
      count += 1
    @stmt._reset!()
    count

# --------------------------------------------------------------- module helpers

def _feature_map(db):
  probes = _feature_probes(db)
  {
    adapter: :sqlite3,
    dialect: :sqlite,
    version: _libversion(),
    source_id: _sourceid(),
    libversion_number: _libversion_number(),
    compile_options: _compile_options(),
    placeholder_style: :qmark,
    named_parameters: true,
    returning: true,
    savepoints: true,
    nested_transactions: :savepoint,
    ddl_transactions: true,
    pool: true,
    pool_wait: :cooperative,
    pool_affinity: :lease,
    pool_context: :task_local,
    json: probes[:json],
    jsonb: probes[:jsonb],
    jsonb_each: probes[:jsonb_each],
    jsonb_tree: probes[:jsonb_tree]
  }

def _feature_probes(db):
  if db:
    {
      json: db.json_available?(),
      jsonb: db.jsonb_available?(),
      jsonb_each: db.jsonb_each_available?(),
      jsonb_tree: db.jsonb_tree_available?()
    }
  else:
    {json: true, jsonb: true, jsonb_each: true, jsonb_tree: true}

def _command_result(db):
  ch = db.changes()
  tot = db.total_changes()
  lid = db.last_insert_rowid()
  {affected_rows: ch, changes: ch, total_changes: tot, last_insert_id: lid, last_insert_rowid: lid}

def _open_flags(mode, uri):
  base = _open_base_flags(mode)
  if uri then base + 64 else base

def _open_base_flags(mode):
  if mode == :readonly:
    1
  elif mode == :readwrite:
    2
  elif mode == :create:
    6
  else:
    raise ArgumentError("invalid mode (expected :readonly, :readwrite, or :create)")

def _busy_ms(t):
  when Null:
    -1
  when Int:
    _check_ms(t * 1000)
  when Float:
    _check_ms((t * 1000.0).to_int)
  else:
    _check_ms((t.total_nanoseconds / 1000000).to_int)

def _check_ms(ms):
  raise ArgumentError("busy_timeout must be non-negative") if ms < 0
  ms

def _validate_pool_sizes(min_size, max_size):
  raise ArgumentError("min_size must be a non-negative Int") unless Int === min_size and min_size >= 0
  raise ArgumentError("max_size must be a positive Int") unless Int === max_size and max_size > 0
  raise ArgumentError("min_size must not exceed max_size") if min_size > max_size
  null

def _pool_duration_ns(value, label, nullable):
  if value == null:
    return -1 if nullable
    raise ArgumentError(label + " must not be null")
  nanoseconds = case value:
    when Int:
      value * 1000000000
    when Float:
      (value * 1000000000.0).to_int
    else:
      value.total_nanoseconds
  raise ArgumentError(label + " must be non-negative") if nanoseconds < 0
  nanoseconds

def _text_of(v):
  when Str:
    v
  else:
    v.to_str

def _path_text(path as (Str | fs.Path)):
  when Str:
    path
  else:
    path.to_str()

def _begin_sql(mode):
  if mode == :deferred:
    "BEGIN DEFERRED"
  elif mode == :immediate:
    "BEGIN IMMEDIATE"
  elif mode == :exclusive:
    "BEGIN EXCLUSIVE"
  else:
    raise ArgumentError("invalid transaction mode (expected :deferred, :immediate, or :exclusive)")

# SQL argument handling -------------------------------------------------------

def _sql_parts(sql, params):
  case sql:
    when SqlFragment:
      if params:
        raise ArgumentError("params: must be null when the SQL fragment already carries parameters")
      pair = [sql.text, sql.params]
      pair
    when Str:
      [sql, params]
    else:
      raise ArgumentError("sql must be a Str or a fragment produced by sqlite3.fragment")

def _prepare_text(sql):
  when Str:
    sql
  when SqlFragment:
    if sql.params.count > 0:
      raise ArgumentError("prepare: a fragment must not carry parameters; use placeholders and pass values to the statement")
    sql.text
  else:
    raise ArgumentError("prepare expects a Str or parameterless fragment")

# parameter shaping -----------------------------------------------------------

def _positional_params(handle, params):
  case params:
    when Null:
      []
    when (Array | Tuple):
      params.to_array
    when (Map | StrictMap):
      _named_positional(handle, params)
    else:
      raise ArgumentError("params must be a List, Tuple, Map, or null")

def _named_positional(handle, map):
  handle._parameter_names.map |slot|:
    _named_value(map, slot)

def _named_value(map, slot):
  raise ArgumentError("a named-parameter Map cannot be used with positional (?) placeholders") unless slot
  bare = slot.slice(1...slot.length)
  if map.has_key?(slot):
    map[slot]
  elif map.has_key?(bare):
    map[bare]
  else:
    raise ArgumentError("missing bind value for parameter " + slot)

def _zip_row(names, values):
  names.zip(values).to_map

# identifiers -----------------------------------------------------------------

def _render_ident(name):
  when SqlIdent:
    name.sql
  when Symbol:
    _quote_one(name.to_str)
  when Str:
    _quote_one(name)
  when (Array | Tuple):
    _render_ident_path(name.to_array)
  else:
    raise ArgumentError("identifier must be a Symbol, Str, List, or SqlIdent")

def _render_ident_path(segments):
  segments.map: _render_ident(_1) .join(".")

def _quote_one(s):
  "\"" + s.replace("\"", "\"\"") + "\""

def _ident_key(c):
  when Symbol:
    c.to_str
  when Str:
    c
  else:
    _render_ident(c)

def _safe_ident(name):
  nm = _text_of(name)
  if not _valid_ident(nm):
    raise ArgumentError("unsafe SQL identifier: " + nm)
  nm

def _valid_ident(s):
  return false if s.length == 0
  s.chars.all?: _ident_char(_1)

def _ident_char(c):
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_".contains?(c)

# convenience-layer SQL builders ----------------------------------------------

def _select_sql(table, columns, where, where_not, group_by, having, order, limit, offset, binds):
  sql = "SELECT " + _columns_clause(columns) + " FROM " + _render_ident(table)
  wc = _where_clause(where, where_not, binds)
  if wc:
    sql = sql + " WHERE " + wc
  if group_by:
    sql = sql + " GROUP BY " + _projection_clause(group_by)
  if having:
    sql = sql + " HAVING " + _predicate_sql(having, binds)
  if order:
    sql = sql + " ORDER BY " + _order_clause(order)
  if limit:
    sql = sql + " LIMIT " + _int_literal(limit)
    if offset:
      sql = sql + " OFFSET " + _int_literal(offset)
  sql

def _columns_clause(columns):
  case columns:
    when Symbol:
      if columns == :all:
        "*"
      else:
        _column_sql(columns)
    else:
      _projection_clause(columns)

def _projection_clause(cols):
  when (Array | Tuple):
    _render_projection(cols.to_array)
  else:
    _column_sql(cols)

def _render_projection(cols):
  cols.map: _column_sql(_1) .join(", ")

def _column_sql(c):
  when SqlFragment:
    c.text
  when SqlIdent:
    c.sql
  when Symbol:
    _quote_one(c.to_str)
  when Str:
    _quote_one(c)
  else:
    raise ArgumentError("invalid column expression")

def _where_clause(where, where_not, binds):
  clauses = []
  if where:
    clauses.push!(_predicate_sql(where, binds))
  if where_not:
    clauses.push!("NOT (" + _predicate_sql(where_not, binds) + ")")
  if clauses.count == 0:
    null
  else:
    clauses.join(" AND ")

def _predicate_sql(pred, binds):
  case pred:
    when SqlFragment:
      pred.params.each |p|:
        binds.push!(p)
      pred.text
    when (Map | StrictMap):
      _map_predicate(pred, binds)
    else:
      raise ArgumentError("predicate must be a Map or a fragment")

def _map_predicate(map, binds):
  parts = map.map |k, v|: _map_term(_render_ident(k), v, binds)
  if parts.count == 0:
    "1 = 1"
  else:
    parts.join(" AND ")

def _map_term(col, v, binds):
  case v:
    when Null:
      col + " IS NULL"
    when (Array | Tuple):
      _in_predicate(col, v.to_array, binds)
    else:
      binds.push!(v)
      col + " = ?"

def _in_predicate(col, seq, binds):
  return "0 = 1" if seq.count == 0
  placeholders = seq.map |v|:
    binds.push!(v)
    "?"
  col + " IN (" + placeholders.join(", ") + ")"

def _order_clause(order):
  when SqlFragment:
    order.text
  when SqlIdent:
    order.sql
  when Symbol:
    _quote_one(order.to_str)
  when Str:
    _quote_one(order)
  when (Array | Tuple):
    _render_order(order.to_array)
  else:
    raise ArgumentError("invalid order expression")

def _render_order(items):
  items.map: _order_term(_1) .join(", ")

def _order_term(item):
  when (Array | Tuple):
    _render_ident(item[0]) + " " + _dir_sql(item[1])
  else:
    _render_ident(item)

def _dir_sql(dir):
  if dir == :asc:
    "ASC"
  elif dir == :desc:
    "DESC"
  else:
    raise ArgumentError("order direction must be :asc or :desc")

def _returning_sql(returning):
  return null unless returning
  case returning:
    when Symbol:
      if returning == :all:
        "*"
      else:
        _column_sql(returning)
    else:
      _as_list(returning)
        .map: _column_sql(_1)
        .join(", ")

def _int_literal(n):
  when Int:
    if n < 0:
      raise ArgumentError("limit/offset must be non-negative")
    n.to_str
  else:
    raise ArgumentError("limit/offset must be a non-negative Int")

# row/value normalization -----------------------------------------------------

def _rows_of(values):
  when (Map | StrictMap):
    [values]
  when (Array | Tuple):
    _rows_from_seq(values.to_array)
  else:
    raise ArgumentError("values must be a row or a list of rows")

def _rows_from_seq(seq):
  raise ArgumentError("values must not be empty") if seq.count == 0
  if _is_row(seq[0]):
    seq.to_array
  else:
    [seq]

def _is_row(v):
  when (Array | Tuple | Map | StrictMap):
    true
  else:
    false

def _row_placeholders(vals, binds):
  placeholders = vals.map |v|:
    binds.push!(v)
    "?"
  "(" + placeholders.join(", ") + ")"

def _row_values(row, col_names):
  case row:
    when (Map | StrictMap):
      _map_row_values(row, col_names)
    when (Array | Tuple):
      _seq_row_values(row.to_array, col_names)
    else:
      raise ArgumentError("row must be a List, Tuple, or Map")

def _seq_row_values(row, col_names):
  raise ArgumentError("row size does not match the number of columns") if row.count != col_names.count
  row.to_array

def _map_row_values(row, col_names):
  col_names.map: _fetch_column(row, _1)

def _fetch_column(row, name):
  if row.has_key?(name):
    row[name]
  else:
    raise ArgumentError("row is missing a value for column " + name)

def _pragma_value_sql(v):
  when Bool:
    _bool_sql(v)
  when (Int | Float):
    v.to_str
  when Symbol:
    _safe_ident(v)
  when Str:
    "'" + v.replace("'", "''") + "'"
  when Null:
    "NULL"
  else:
    raise ArgumentError("unsupported pragma value")

def _bool_sql(v):
  if v then "1" else "0"

def _require_map(v, label):
  case v:
    when (Map | StrictMap):
      v
    else:
      raise ArgumentError(label + " must be a Map")

def _as_list(v):
  when (Array | Tuple):
    v.to_array
  else:
    [v]

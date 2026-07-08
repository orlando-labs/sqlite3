/*
 * sqlite3_ext.c — native leaves for the Amber `sqlite3` package.
 *
 * These thunks are the *only* C in the package. They speak the amber_ext ABI
 * (runtime/amber_ext.h), which exposes just null/bool/int/float/str/bytes/list
 * plus foreign handles — no maps, no symbols, no keyword args. So the leaves
 * stay deliberately low-level: SQL arrives as a Str, bind values arrive as a
 * flat List of scalars, and rows leave as a List of column-value Lists. All the
 * map/symbol/keyword shaping, the convenience SQL builders, and transactions
 * live in Amber (src/sqlite3.am), per the design's anchor #1 ("The Amber source
 * is the public API. C is only the implementation of native-only leaves.").
 *
 * Every thunk uses an `amsq_` prefix so no name can collide with a real
 * `sqlite3_*` symbol from the amalgamation.
 *
 * Two foreign-handle types are registered in amber.build.json:
 *   sqlite3.Conn  -> struct Conn  (wraps sqlite3*)      owned
 *   sqlite3.Stmt  -> struct Stmt  (wraps sqlite3_stmt*) owned
 */
#include "runtime/amber_ext.h"

#include "sqlite3.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ handles */

typedef struct {
  sqlite3 *db;
} Conn;

typedef struct {
  sqlite3_stmt *stmt;
} Stmt;

static const char kConnTag[] = "sqlite3.Conn";
static const char kStmtTag[] = "sqlite3.Stmt";

/* ------------------------------------------------------------ error mapping */

/* Map a primary SQLite result code to the package error class name. Extended
 * codes are reduced to their primary (rc & 0xff) for classification. */
static const char *error_class_for_rc(int rc) {
  switch (rc & 0xff) {
  case SQLITE_BUSY:
    return "Sqlite3.BusyError";
  case SQLITE_LOCKED:
    return "Sqlite3.LockedError";
  case SQLITE_CONSTRAINT:
    return "Sqlite3.ConstraintError";
  case SQLITE_READONLY:
    return "Sqlite3.ReadOnlyError";
  case SQLITE_RANGE:
    return "Sqlite3.RangeError";
  case SQLITE_MISUSE:
    return "Sqlite3.MisuseError";
  case SQLITE_INTERRUPT:
    return "Sqlite3.InterruptError";
  case SQLITE_CORRUPT:
    return "Sqlite3.CorruptError";
  default:
    return NULL;
  }
}

/* Record a fault for `rc`, preferring the specific class, else the phase parent
 * ("Sqlite3.OpenError" / ".PrepareError" / ".BindError" / ".StepError"). */
static AmberStatus fault_for_rc(AmberCtx *cx, sqlite3 *db, int rc,
                                const char *phase_class) {
  const char *cls = error_class_for_rc(rc);
  if (cls == NULL) {
    cls = phase_class;
  }
  const char *msg = NULL;
  if (db != NULL) {
    msg = sqlite3_errmsg(db);
  }
  if (msg == NULL || msg[0] == '\0') {
    msg = sqlite3_errstr(rc);
  }
  return amber_fault(cx, cls, msg != NULL ? msg : "sqlite3 error");
}

/* ------------------------------------------------------------ arg utilities */

static int arg_int(AmberCtx *cx, const AmberValue *args, size_t argc, size_t i,
                   int64_t *out) {
  if (i >= argc) {
    return 0;
  }
  return amber_as_int(cx, args[i], out);
}

/* Borrow the UTF-8 text of a Str argument. Returns 0 (no fault) if not a Str. */
static int arg_str(AmberCtx *cx, const AmberValue *args, size_t argc, size_t i,
                   const char **ptr, size_t *len) {
  if (i >= argc) {
    return 0;
  }
  return amber_str_view(cx, args[i], ptr, len);
}

/* raise(class, message) -> never. Lets the Amber layer raise any registered
 * package error class (which are declared in amber.build.json and raised via
 * amber_fault, the proven-rescuable path) without depending on Amber-side
 * construction of manifest-registered error classes. */
AmberStatus amsq_raise(AmberCtx *cx, const AmberValue *args, size_t argc,
                       AmberValue *out) {
  (void)out;
  const char *cls = NULL;
  size_t cls_len = 0;
  const char *msg = NULL;
  size_t msg_len = 0;
  if (!arg_str(cx, args, argc, 0, &cls, &cls_len) ||
      !arg_str(cx, args, argc, 1, &msg, &msg_len)) {
    return amber_fault(cx, "TypeError", "raise expects (Str class, Str message)");
  }
  char cbuf[160];
  char mbuf[1024];
  if (cls_len >= sizeof(cbuf)) {
    cls_len = sizeof(cbuf) - 1;
  }
  if (msg_len >= sizeof(mbuf)) {
    msg_len = sizeof(mbuf) - 1;
  }
  memcpy(cbuf, cls, cls_len);
  cbuf[cls_len] = '\0';
  memcpy(mbuf, msg, msg_len);
  mbuf[msg_len] = '\0';
  return amber_fault(cx, cbuf, mbuf);
}

/* ---------------------------------------------------------- library globals */

AmberStatus amsq_libversion(AmberCtx *cx, const AmberValue *args, size_t argc,
                            AmberValue *out) {
  (void)args;
  (void)argc;
  const char *v = sqlite3_libversion();
  *out = amber_make_str(cx, v, strlen(v));
  return AMBER_OK;
}

AmberStatus amsq_sourceid(AmberCtx *cx, const AmberValue *args, size_t argc,
                          AmberValue *out) {
  (void)args;
  (void)argc;
  const char *v = sqlite3_sourceid();
  *out = amber_make_str(cx, v, strlen(v));
  return AMBER_OK;
}

AmberStatus amsq_libversion_number(AmberCtx *cx, const AmberValue *args,
                                   size_t argc, AmberValue *out) {
  (void)args;
  (void)argc;
  *out = amber_make_int(cx, sqlite3_libversion_number());
  return AMBER_OK;
}

AmberStatus amsq_compile_options(AmberCtx *cx, const AmberValue *args,
                                 size_t argc, AmberValue *out) {
  (void)args;
  (void)argc;
  AmberValue items[512];
  size_t n = 0;
  const char *opt = NULL;
  int i = 0;
  while (n < 512 && (opt = sqlite3_compileoption_get(i++)) != NULL) {
    items[n++] = amber_make_str(cx, opt, strlen(opt));
  }
  *out = amber_make_list(cx, items, n);
  return AMBER_OK;
}

/* -------------------------------------------------------------- connection */

/* init(path, flags, busy_ms) -> Conn. busy_ms < 0 leaves the default. */
AmberStatus amsq_conn_open(AmberCtx *cx, const AmberValue *args, size_t argc,
                           AmberValue *out) {
  const char *path = NULL;
  size_t path_len = 0;
  int64_t flags = 0;
  int64_t busy_ms = -1;
  if (!arg_str(cx, args, argc, 0, &path, &path_len) ||
      !arg_int(cx, args, argc, 1, &flags) ||
      !arg_int(cx, args, argc, 2, &busy_ms)) {
    return amber_fault(cx, "TypeError",
                       "conn_open expects (Str path, Int flags, Int busy_ms)");
  }
  char *path_z = (char *)malloc(path_len + 1);
  if (path_z == NULL) {
    return amber_fault(cx, "Sqlite3.OpenError", "out of memory");
  }
  memcpy(path_z, path, path_len);
  path_z[path_len] = '\0';

  sqlite3 *db = NULL;
  int rc = sqlite3_open_v2(path_z, &db, (int)flags, NULL);
  free(path_z);
  if (rc != SQLITE_OK) {
    AmberStatus st = fault_for_rc(cx, db, rc, "Sqlite3.OpenError");
    sqlite3_close_v2(db);
    return st;
  }
  sqlite3_extended_result_codes(db, 1);
  if (busy_ms >= 0) {
    sqlite3_busy_timeout(db, (int)busy_ms);
  }
  Conn *conn = (Conn *)malloc(sizeof(Conn));
  if (conn == NULL) {
    sqlite3_close_v2(db);
    return amber_fault(cx, "Sqlite3.OpenError", "out of memory");
  }
  conn->db = db;
  *out = amber_make_handle(cx, kConnTag, conn);
  return AMBER_OK;
}

static Conn *conn_of(AmberCtx *cx, AmberValue self) {
  void *p = NULL;
  if (!amber_handle_ptr(cx, self, kConnTag, &p)) {
    return NULL;
  }
  return (Conn *)p;
}

AmberStatus amsq_conn_close(AmberCtx *cx, AmberValue self,
                            const AmberValue *args, size_t argc,
                            AmberValue *out) {
  (void)args;
  (void)argc;
  Conn *conn = conn_of(cx, self);
  if (conn == NULL) {
    return AMBER_ERR;
  }
  if (conn->db != NULL) {
    sqlite3_close_v2(conn->db);
    conn->db = NULL;
  }
  *out = amber_make_null(cx);
  return AMBER_OK;
}

/* owned destructor: (cx, handle) — behaves like close!, then frees the box. */
void amsq_conn_free(AmberCtx *cx, void *handle) {
  (void)cx;
  Conn *conn = (Conn *)handle;
  if (conn == NULL) {
    return;
  }
  if (conn->db != NULL) {
    sqlite3_close_v2(conn->db);
    conn->db = NULL;
  }
  free(conn);
}

AmberStatus amsq_conn_closed(AmberCtx *cx, AmberValue self,
                             const AmberValue *args, size_t argc,
                             AmberValue *out) {
  (void)args;
  (void)argc;
  Conn *conn = conn_of(cx, self);
  if (conn == NULL) {
    return AMBER_ERR;
  }
  *out = amber_make_bool(cx, conn->db == NULL);
  return AMBER_OK;
}

/* Guard: refuse a NULL (closed) db with a rescuable LifetimeError. */
static sqlite3 *live_db(AmberCtx *cx, AmberValue self) {
  Conn *conn = conn_of(cx, self);
  if (conn == NULL) {
    return NULL;
  }
  if (conn->db == NULL) {
    amber_fault(cx, "LifetimeError", "database is closed");
    return NULL;
  }
  return conn->db;
}

/* Copy a Str-or-default schema argument into a small NUL-terminated buffer. */
static void schema_arg(AmberCtx *cx, const AmberValue *args, size_t argc,
                       char *buf, size_t bufsz) {
  const char *schema = "main";
  size_t schema_len = 4;
  const char *sv = NULL;
  size_t sl = 0;
  if (arg_str(cx, args, argc, 0, &sv, &sl)) {
    schema = sv;
    schema_len = sl;
  }
  if (schema_len >= bufsz) {
    schema_len = bufsz - 1;
  }
  memcpy(buf, schema, schema_len);
  buf[schema_len] = '\0';
}

AmberStatus amsq_conn_filename(AmberCtx *cx, AmberValue self,
                               const AmberValue *args, size_t argc,
                               AmberValue *out) {
  sqlite3 *db = live_db(cx, self);
  if (db == NULL) {
    return AMBER_ERR;
  }
  char sbuf[128];
  schema_arg(cx, args, argc, sbuf, sizeof(sbuf));
  const char *name = sqlite3_db_filename(db, sbuf);
  if (name == NULL) {
    name = "";
  }
  *out = amber_make_str(cx, name, strlen(name));
  return AMBER_OK;
}

AmberStatus amsq_conn_readonly(AmberCtx *cx, AmberValue self,
                               const AmberValue *args, size_t argc,
                               AmberValue *out) {
  sqlite3 *db = live_db(cx, self);
  if (db == NULL) {
    return AMBER_ERR;
  }
  char sbuf[128];
  schema_arg(cx, args, argc, sbuf, sizeof(sbuf));
  int ro = sqlite3_db_readonly(db, sbuf);
  *out = amber_make_bool(cx, ro == 1);
  return AMBER_OK;
}

AmberStatus amsq_conn_in_transaction(AmberCtx *cx, AmberValue self,
                                     const AmberValue *args, size_t argc,
                                     AmberValue *out) {
  (void)args;
  (void)argc;
  sqlite3 *db = live_db(cx, self);
  if (db == NULL) {
    return AMBER_ERR;
  }
  *out = amber_make_bool(cx, sqlite3_get_autocommit(db) == 0);
  return AMBER_OK;
}

AmberStatus amsq_conn_changes(AmberCtx *cx, AmberValue self,
                              const AmberValue *args, size_t argc,
                              AmberValue *out) {
  (void)args;
  (void)argc;
  sqlite3 *db = live_db(cx, self);
  if (db == NULL) {
    return AMBER_ERR;
  }
  *out = amber_make_int(cx, sqlite3_changes64(db));
  return AMBER_OK;
}

AmberStatus amsq_conn_total_changes(AmberCtx *cx, AmberValue self,
                                    const AmberValue *args, size_t argc,
                                    AmberValue *out) {
  (void)args;
  (void)argc;
  sqlite3 *db = live_db(cx, self);
  if (db == NULL) {
    return AMBER_ERR;
  }
  *out = amber_make_int(cx, sqlite3_total_changes64(db));
  return AMBER_OK;
}

AmberStatus amsq_conn_last_insert_rowid(AmberCtx *cx, AmberValue self,
                                        const AmberValue *args, size_t argc,
                                        AmberValue *out) {
  (void)args;
  (void)argc;
  sqlite3 *db = live_db(cx, self);
  if (db == NULL) {
    return AMBER_ERR;
  }
  *out = amber_make_int(cx, sqlite3_last_insert_rowid(db));
  return AMBER_OK;
}

AmberStatus amsq_conn_interrupt(AmberCtx *cx, AmberValue self,
                                const AmberValue *args, size_t argc,
                                AmberValue *out) {
  (void)args;
  (void)argc;
  sqlite3 *db = live_db(cx, self);
  if (db == NULL) {
    return AMBER_ERR;
  }
  sqlite3_interrupt(db);
  *out = amber_make_null(cx);
  return AMBER_OK;
}

AmberStatus amsq_conn_busy_timeout(AmberCtx *cx, AmberValue self,
                                   const AmberValue *args, size_t argc,
                                   AmberValue *out) {
  sqlite3 *db = live_db(cx, self);
  if (db == NULL) {
    return AMBER_ERR;
  }
  int64_t ms = 0;
  if (!arg_int(cx, args, argc, 0, &ms)) {
    return amber_fault(cx, "TypeError", "busy_timeout expects Int milliseconds");
  }
  sqlite3_busy_timeout(db, (int)ms);
  *out = amber_make_null(cx);
  return AMBER_OK;
}

/* ---------------------------------------------------- ATTACH / VACUUM guard */

/* Case-insensitive check that `sql` begins (after leading whitespace) with
 * `word`, followed by a non-identifier char. Conservative: used only to reject
 * file-escaping statements. */
static int begins_with_keyword(const char *sql, size_t len, const char *word) {
  size_t i = 0;
  while (i < len && (sql[i] == ' ' || sql[i] == '\t' || sql[i] == '\n' ||
                     sql[i] == '\r')) {
    i++;
  }
  size_t wlen = strlen(word);
  if (len - i < wlen) {
    return 0;
  }
  for (size_t k = 0; k < wlen; k++) {
    char c = sql[i + k];
    if (c >= 'a' && c <= 'z') {
      c = (char)(c - 32);
    }
    if (c != word[k]) {
      return 0;
    }
  }
  char after = (i + wlen < len) ? sql[i + wlen] : ' ';
  int is_ident = (after >= 'a' && after <= 'z') ||
                 (after >= 'A' && after <= 'Z') ||
                 (after >= '0' && after <= '9') || after == '_';
  return !is_ident;
}

/* Reject ATTACH/DETACH and `VACUUM ... INTO`, which can open or write files
 * outside the original database path (design §11, §15). Best-effort textual
 * guard for v1. */
static AmberStatus reject_file_escape(AmberCtx *cx, const char *sql,
                                      size_t len) {
  if (begins_with_keyword(sql, len, "ATTACH") ||
      begins_with_keyword(sql, len, "DETACH")) {
    return amber_fault(cx, "Sqlite3.MisuseError",
                       "ATTACH/DETACH is not permitted (a future attach() API "
                       "will add explicit capability checks)");
  }
  if (begins_with_keyword(sql, len, "VACUUM")) {
    for (size_t i = 0; i + 4 <= len; i++) {
      char a = sql[i], b = sql[i + 1], c = sql[i + 2], d = sql[i + 3];
      if ((a == 'I' || a == 'i') && (b == 'N' || b == 'n') &&
          (c == 'T' || c == 't') && (d == 'O' || d == 'o')) {
        return amber_fault(cx, "Sqlite3.MisuseError",
                           "VACUUM INTO is not permitted (a future "
                           "vacuum_into() API will add capability checks)");
      }
    }
  }
  return AMBER_OK;
}

/* exec(sql) -> null. Trusted multi-statement path; no separate parameters. */
AmberStatus amsq_conn_exec(AmberCtx *cx, AmberValue self, const AmberValue *args,
                           size_t argc, AmberValue *out) {
  sqlite3 *db = live_db(cx, self);
  if (db == NULL) {
    return AMBER_ERR;
  }
  const char *sql = NULL;
  size_t sql_len = 0;
  if (!arg_str(cx, args, argc, 0, &sql, &sql_len)) {
    return amber_fault(cx, "TypeError", "exec expects a Str");
  }
  if (reject_file_escape(cx, sql, sql_len) != AMBER_OK) {
    return AMBER_ERR;
  }
  char *errmsg = NULL;
  int rc = sqlite3_exec(db, sql, NULL, NULL, &errmsg);
  if (rc != SQLITE_OK) {
    const char *cls = error_class_for_rc(rc);
    if (cls == NULL) {
      cls = "Sqlite3.StepError";
    }
    AmberStatus st =
        amber_fault(cx, cls, errmsg != NULL ? errmsg : sqlite3_errstr(rc));
    if (errmsg != NULL) {
      sqlite3_free(errmsg);
    }
    return st;
  }
  if (errmsg != NULL) {
    sqlite3_free(errmsg);
  }
  *out = amber_make_null(cx);
  return AMBER_OK;
}

/* prepare(sql) -> Stmt. Prepares exactly one statement and rejects trailing
 * non-whitespace SQL (design §6.1). */
AmberStatus amsq_conn_prepare(AmberCtx *cx, AmberValue self,
                              const AmberValue *args, size_t argc,
                              AmberValue *out) {
  sqlite3 *db = live_db(cx, self);
  if (db == NULL) {
    return AMBER_ERR;
  }
  const char *sql = NULL;
  size_t sql_len = 0;
  if (!arg_str(cx, args, argc, 0, &sql, &sql_len)) {
    return amber_fault(cx, "TypeError", "prepare expects a Str");
  }
  if (reject_file_escape(cx, sql, sql_len) != AMBER_OK) {
    return AMBER_ERR;
  }
  sqlite3_stmt *stmt = NULL;
  const char *tail = NULL;
  int rc = sqlite3_prepare_v3(db, sql, (int)sql_len, 0, &stmt, &tail);
  if (rc != SQLITE_OK) {
    return fault_for_rc(cx, db, rc, "Sqlite3.PrepareError");
  }
  if (stmt == NULL) {
    return amber_fault(cx, "Sqlite3.PrepareError",
                       "no statement to prepare (empty SQL)");
  }
  if (tail != NULL) {
    const char *p = tail;
    const char *end = sql + sql_len;
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' ||
                       *p == ';')) {
      p++;
    }
    if (p < end) {
      sqlite3_finalize(stmt);
      return amber_fault(cx, "Sqlite3.PrepareError",
                         "trailing SQL after the first statement is not "
                         "allowed here (use exec for multi-statement scripts)");
    }
  }
  Stmt *box = (Stmt *)malloc(sizeof(Stmt));
  if (box == NULL) {
    sqlite3_finalize(stmt);
    return amber_fault(cx, "Sqlite3.PrepareError", "out of memory");
  }
  box->stmt = stmt;
  *out = amber_make_handle(cx, kStmtTag, box);
  return AMBER_OK;
}

/* probe(sql) -> Bool. Live feature probe: can the connection compile `sql`? */
AmberStatus amsq_conn_probe(AmberCtx *cx, AmberValue self,
                            const AmberValue *args, size_t argc,
                            AmberValue *out) {
  sqlite3 *db = live_db(cx, self);
  if (db == NULL) {
    return AMBER_ERR;
  }
  const char *probe_sql = NULL;
  size_t probe_len = 0;
  if (!arg_str(cx, args, argc, 0, &probe_sql, &probe_len)) {
    return amber_fault(cx, "TypeError", "probe expects a Str");
  }
  sqlite3_stmt *stmt = NULL;
  int rc = sqlite3_prepare_v2(db, probe_sql, (int)probe_len, &stmt, NULL);
  if (stmt != NULL) {
    sqlite3_finalize(stmt);
  }
  *out = amber_make_bool(cx, rc == SQLITE_OK);
  return AMBER_OK;
}

/* --------------------------------------------------------------- statement */

static Stmt *stmt_of(AmberCtx *cx, AmberValue self) {
  void *p = NULL;
  if (!amber_handle_ptr(cx, self, kStmtTag, &p)) {
    return NULL;
  }
  return (Stmt *)p;
}

static sqlite3_stmt *live_stmt(AmberCtx *cx, AmberValue self) {
  Stmt *box = stmt_of(cx, self);
  if (box == NULL) {
    return NULL;
  }
  if (box->stmt == NULL) {
    amber_fault(cx, "LifetimeError", "statement is closed");
    return NULL;
  }
  return box->stmt;
}

AmberStatus amsq_stmt_finalize(AmberCtx *cx, AmberValue self,
                               const AmberValue *args, size_t argc,
                               AmberValue *out) {
  (void)args;
  (void)argc;
  Stmt *box = stmt_of(cx, self);
  if (box == NULL) {
    return AMBER_ERR;
  }
  if (box->stmt != NULL) {
    sqlite3_finalize(box->stmt);
    box->stmt = NULL;
  }
  *out = amber_make_null(cx);
  return AMBER_OK;
}

void amsq_stmt_free(AmberCtx *cx, void *handle) {
  (void)cx;
  Stmt *box = (Stmt *)handle;
  if (box == NULL) {
    return;
  }
  if (box->stmt != NULL) {
    sqlite3_finalize(box->stmt);
    box->stmt = NULL;
  }
  free(box);
}

AmberStatus amsq_stmt_closed(AmberCtx *cx, AmberValue self,
                             const AmberValue *args, size_t argc,
                             AmberValue *out) {
  (void)args;
  (void)argc;
  Stmt *box = stmt_of(cx, self);
  if (box == NULL) {
    return AMBER_ERR;
  }
  *out = amber_make_bool(cx, box->stmt == NULL);
  return AMBER_OK;
}

AmberStatus amsq_stmt_sql(AmberCtx *cx, AmberValue self, const AmberValue *args,
                          size_t argc, AmberValue *out) {
  (void)args;
  (void)argc;
  sqlite3_stmt *stmt = live_stmt(cx, self);
  if (stmt == NULL) {
    return AMBER_ERR;
  }
  const char *s = sqlite3_sql(stmt);
  if (s == NULL) {
    s = "";
  }
  *out = amber_make_str(cx, s, strlen(s));
  return AMBER_OK;
}

AmberStatus amsq_stmt_column_count(AmberCtx *cx, AmberValue self,
                                   const AmberValue *args, size_t argc,
                                   AmberValue *out) {
  (void)args;
  (void)argc;
  sqlite3_stmt *stmt = live_stmt(cx, self);
  if (stmt == NULL) {
    return AMBER_ERR;
  }
  *out = amber_make_int(cx, sqlite3_column_count(stmt));
  return AMBER_OK;
}

AmberStatus amsq_stmt_column_names(AmberCtx *cx, AmberValue self,
                                   const AmberValue *args, size_t argc,
                                   AmberValue *out) {
  (void)args;
  (void)argc;
  sqlite3_stmt *stmt = live_stmt(cx, self);
  if (stmt == NULL) {
    return AMBER_ERR;
  }
  int n = sqlite3_column_count(stmt);
  AmberValue *items = NULL;
  if (n > 0) {
    items = (AmberValue *)malloc(sizeof(AmberValue) * (size_t)n);
    if (items == NULL) {
      return amber_fault(cx, "Sqlite3.Error", "out of memory");
    }
  }
  for (int i = 0; i < n; i++) {
    const char *name = sqlite3_column_name(stmt, i);
    if (name == NULL) {
      name = "";
    }
    items[i] = amber_make_str(cx, name, strlen(name));
  }
  *out = amber_make_list(cx, items, (size_t)n);
  free(items);
  return AMBER_OK;
}

/* column_meta() -> List of [name, database, table, origin, decltype]. Missing
 * metadata entries are empty strings. */
AmberStatus amsq_stmt_column_meta(AmberCtx *cx, AmberValue self,
                                  const AmberValue *args, size_t argc,
                                  AmberValue *out) {
  (void)args;
  (void)argc;
  sqlite3_stmt *stmt = live_stmt(cx, self);
  if (stmt == NULL) {
    return AMBER_ERR;
  }
  int n = sqlite3_column_count(stmt);
  AmberValue rows[256];
  if (n > 256) {
    n = 256;
  }
  for (int i = 0; i < n; i++) {
    const char *name = sqlite3_column_name(stmt, i);
    const char *dbname = NULL;
    const char *table = NULL;
    const char *origin = NULL;
    const char *decl = sqlite3_column_decltype(stmt, i);
#ifdef SQLITE_ENABLE_COLUMN_METADATA
    dbname = sqlite3_column_database_name(stmt, i);
    table = sqlite3_column_table_name(stmt, i);
    origin = sqlite3_column_origin_name(stmt, i);
#endif
    AmberValue fields[5];
    fields[0] = amber_make_str(cx, name ? name : "", name ? strlen(name) : 0);
    fields[1] =
        amber_make_str(cx, dbname ? dbname : "", dbname ? strlen(dbname) : 0);
    fields[2] =
        amber_make_str(cx, table ? table : "", table ? strlen(table) : 0);
    fields[3] =
        amber_make_str(cx, origin ? origin : "", origin ? strlen(origin) : 0);
    fields[4] = amber_make_str(cx, decl ? decl : "", decl ? strlen(decl) : 0);
    rows[i] = amber_make_list(cx, fields, 5);
  }
  *out = amber_make_list(cx, rows, (size_t)n);
  return AMBER_OK;
}

AmberStatus amsq_stmt_parameter_count(AmberCtx *cx, AmberValue self,
                                      const AmberValue *args, size_t argc,
                                      AmberValue *out) {
  (void)args;
  (void)argc;
  sqlite3_stmt *stmt = live_stmt(cx, self);
  if (stmt == NULL) {
    return AMBER_ERR;
  }
  *out = amber_make_int(cx, sqlite3_bind_parameter_count(stmt));
  return AMBER_OK;
}

/* parameter_names() -> List. Positional slots yield null; named slots yield the
 * SQLite spelling with prefix, e.g. ":id". */
AmberStatus amsq_stmt_parameter_names(AmberCtx *cx, AmberValue self,
                                      const AmberValue *args, size_t argc,
                                      AmberValue *out) {
  (void)args;
  (void)argc;
  sqlite3_stmt *stmt = live_stmt(cx, self);
  if (stmt == NULL) {
    return AMBER_ERR;
  }
  int n = sqlite3_bind_parameter_count(stmt);
  AmberValue items[512];
  if (n > 512) {
    n = 512;
  }
  for (int i = 1; i <= n; i++) {
    const char *name = sqlite3_bind_parameter_name(stmt, i);
    if (name == NULL) {
      items[i - 1] = amber_make_null(cx);
    } else {
      items[i - 1] = amber_make_str(cx, name, strlen(name));
    }
  }
  *out = amber_make_list(cx, items, (size_t)n);
  return AMBER_OK;
}

AmberStatus amsq_stmt_readonly(AmberCtx *cx, AmberValue self,
                               const AmberValue *args, size_t argc,
                               AmberValue *out) {
  (void)args;
  (void)argc;
  sqlite3_stmt *stmt = live_stmt(cx, self);
  if (stmt == NULL) {
    return AMBER_ERR;
  }
  *out = amber_make_bool(cx, sqlite3_stmt_readonly(stmt) != 0);
  return AMBER_OK;
}

AmberStatus amsq_stmt_busy(AmberCtx *cx, AmberValue self, const AmberValue *args,
                           size_t argc, AmberValue *out) {
  (void)args;
  (void)argc;
  sqlite3_stmt *stmt = live_stmt(cx, self);
  if (stmt == NULL) {
    return AMBER_ERR;
  }
  *out = amber_make_bool(cx, sqlite3_stmt_busy(stmt) != 0);
  return AMBER_OK;
}

AmberStatus amsq_stmt_reset(AmberCtx *cx, AmberValue self,
                            const AmberValue *args, size_t argc,
                            AmberValue *out) {
  (void)args;
  (void)argc;
  sqlite3_stmt *stmt = live_stmt(cx, self);
  if (stmt == NULL) {
    return AMBER_ERR;
  }
  sqlite3_reset(stmt);
  *out = amber_make_null(cx);
  return AMBER_OK;
}

AmberStatus amsq_stmt_clear_bindings(AmberCtx *cx, AmberValue self,
                                     const AmberValue *args, size_t argc,
                                     AmberValue *out) {
  (void)args;
  (void)argc;
  sqlite3_stmt *stmt = live_stmt(cx, self);
  if (stmt == NULL) {
    return AMBER_ERR;
  }
  sqlite3_clear_bindings(stmt);
  *out = amber_make_null(cx);
  return AMBER_OK;
}

/* Bind one Amber scalar value to slot `idx` (1-based). */
static AmberStatus bind_one(AmberCtx *cx, sqlite3 *db, sqlite3_stmt *stmt,
                            int idx, AmberValue v) {
  int rc = SQLITE_OK;
  if (amber_is_null(cx, v)) {
    rc = sqlite3_bind_null(stmt, idx);
  } else if (amber_is_bool(cx, v)) {
    int b = 0;
    amber_as_bool(cx, v, &b);
    rc = sqlite3_bind_int64(stmt, idx, b ? 1 : 0);
  } else if (amber_is_int(cx, v)) {
    int64_t n = 0;
    amber_as_int(cx, v, &n);
    rc = sqlite3_bind_int64(stmt, idx, n);
  } else if (amber_is_float(cx, v)) {
    double d = 0;
    amber_as_float(cx, v, &d);
    rc = sqlite3_bind_double(stmt, idx, d);
  } else if (amber_is_str(cx, v)) {
    const char *p = NULL;
    size_t len = 0;
    amber_str_view(cx, v, &p, &len);
    rc = sqlite3_bind_text(stmt, idx, p, (int)len, SQLITE_TRANSIENT);
  } else if (amber_is_bytes(cx, v)) {
    const uint8_t *p = NULL;
    size_t len = 0;
    amber_bytes_view(cx, v, &p, &len);
    rc = sqlite3_bind_blob(stmt, idx, p, (int)len, SQLITE_TRANSIENT);
  } else {
    return amber_fault(cx, "TypeError",
                       "unsupported bind value (expected null, Bool, Int, "
                       "Float, Str, or Bytes)");
  }
  if (rc != SQLITE_OK) {
    return fault_for_rc(cx, db, rc, "Sqlite3.BindError");
  }
  return AMBER_OK;
}

/* bind(values) -> null. Binds values[i] to slot i+1. The Amber layer builds the
 * positional list (resolving named params to order). */
AmberStatus amsq_stmt_bind(AmberCtx *cx, AmberValue self, const AmberValue *args,
                           size_t argc, AmberValue *out) {
  sqlite3_stmt *stmt = live_stmt(cx, self);
  if (stmt == NULL) {
    return AMBER_ERR;
  }
  if (argc != 1 || !amber_is_list(cx, args[0])) {
    return amber_fault(cx, "TypeError", "bind expects a List of values");
  }
  sqlite3 *db = sqlite3_db_handle(stmt);
  size_t count = amber_list_len(cx, args[0]);
  int expected = sqlite3_bind_parameter_count(stmt);
  if ((int)count != expected) {
    return amber_fault(cx, "Sqlite3.BindError",
                       "wrong number of bind values for statement");
  }
  for (size_t i = 0; i < count; i++) {
    AmberValue v = amber_list_at(cx, args[0], i);
    AmberStatus st = bind_one(cx, db, stmt, (int)i + 1, v);
    if (st != AMBER_OK) {
      return st;
    }
  }
  *out = amber_make_null(cx);
  return AMBER_OK;
}

/* Build a List of the current row's column values. */
static AmberValue row_values(AmberCtx *cx, sqlite3_stmt *stmt) {
  int n = sqlite3_column_count(stmt);
  AmberValue small[64];
  AmberValue *items = small;
  if (n > 64) {
    items = (AmberValue *)malloc(sizeof(AmberValue) * (size_t)n);
  }
  for (int i = 0; i < n; i++) {
    int t = sqlite3_column_type(stmt, i);
    if (t == SQLITE_NULL) {
      items[i] = amber_make_null(cx);
    } else if (t == SQLITE_INTEGER) {
      items[i] = amber_make_int(cx, sqlite3_column_int64(stmt, i));
    } else if (t == SQLITE_FLOAT) {
      items[i] = amber_make_float(cx, sqlite3_column_double(stmt, i));
    } else if (t == SQLITE_TEXT) {
      const char *p = (const char *)sqlite3_column_text(stmt, i);
      int len = sqlite3_column_bytes(stmt, i);
      items[i] = amber_make_str(cx, p ? p : "", (size_t)(len < 0 ? 0 : len));
    } else { /* SQLITE_BLOB */
      const void *p = sqlite3_column_blob(stmt, i);
      int len = sqlite3_column_bytes(stmt, i);
      items[i] =
          amber_make_bytes(cx, (const uint8_t *)p, (size_t)(len < 0 ? 0 : len));
    }
  }
  AmberValue list = amber_make_list(cx, items, (size_t)n);
  if (items != small) {
    free(items);
  }
  return list;
}

/* rows() -> List of row-value Lists. Steps the statement to completion in one
 * native call (fewer round-trips than driving step() from Amber). */
AmberStatus amsq_stmt_rows(AmberCtx *cx, AmberValue self, const AmberValue *args,
                           size_t argc, AmberValue *out) {
  (void)args;
  (void)argc;
  sqlite3_stmt *stmt = live_stmt(cx, self);
  if (stmt == NULL) {
    return AMBER_ERR;
  }
  size_t cap = 16;
  size_t n = 0;
  AmberValue *rows = (AmberValue *)malloc(cap * sizeof(AmberValue));
  if (rows == NULL) {
    return amber_fault(cx, "Sqlite3.Error", "out of memory");
  }
  int rc = 0;
  while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
    if (n == cap) {
      cap *= 2;
      AmberValue *grown = (AmberValue *)realloc(rows, cap * sizeof(AmberValue));
      if (grown == NULL) {
        free(rows);
        return amber_fault(cx, "Sqlite3.Error", "out of memory");
      }
      rows = grown;
    }
    rows[n++] = row_values(cx, stmt);
  }
  if (rc != SQLITE_DONE) {
    AmberStatus st =
        fault_for_rc(cx, sqlite3_db_handle(stmt), rc, "Sqlite3.StepError");
    free(rows);
    return st;
  }
  *out = amber_make_list(cx, rows, n);
  free(rows);
  return AMBER_OK;
}

/* step() -> List (row values) on a row, or null when the statement is done. */
AmberStatus amsq_stmt_step(AmberCtx *cx, AmberValue self, const AmberValue *args,
                           size_t argc, AmberValue *out) {
  (void)args;
  (void)argc;
  sqlite3_stmt *stmt = live_stmt(cx, self);
  if (stmt == NULL) {
    return AMBER_ERR;
  }
  int rc = sqlite3_step(stmt);
  if (rc == SQLITE_ROW) {
    *out = row_values(cx, stmt);
    return AMBER_OK;
  }
  if (rc == SQLITE_DONE) {
    *out = amber_make_null(cx);
    return AMBER_OK;
  }
  return fault_for_rc(cx, sqlite3_db_handle(stmt), rc, "Sqlite3.StepError");
}

/* Note: amber_ext_abi_version() is intentionally NOT defined here. When this
 * package is built in-tree, the Amber runtime archive already provides that
 * symbol; defining it again is a duplicate-symbol link error. A standalone
 * (out-of-tree) build against a prebuilt libamber would add it in its own
 * shim. */

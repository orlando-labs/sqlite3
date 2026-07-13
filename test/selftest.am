package sqlite3.selftest

import sqlite3
from sqlite3 import fragment, ident, quote_identifier, sql

export main

# Each check adds 1 to the score on success. main returns the total; the build
# harness asserts it equals EXPECTED below.
EXPECTED = 35

class QueryProbe:
  attr executions

  def init():
    @executions = []
  def instrument(execution, &execute):
    @executions.push!(execution)
    execute()

def check(score, cond):
  if cond:
    score + 1
  else:
    score

def main():
  score = 0

  # --- library metadata -------------------------------------------------
  score = check(score, sqlite3.version().length() > 0)
  score = check(score, sqlite3.libversion_number() >= 3045000)
  feats = sqlite3.features()
  score = check(score, feats[:adapter] == :sqlite3 and feats[:placeholder_style] == :qmark)

  sqlite3.open(fs.Path(":memory:")) |path_db|:
    path_db.exec("create table from_path(v integer)")
    path_db.execute("insert into from_path(v) values (?)", params: [7])
    score = check(score, path_db.scalar("select v from from_path") == 7)

  sqlite3.connect(fs.Path(":memory:")) |path_db|:
    path_db.exec("create table from_connect(v integer)")
    path_db.execute("insert into from_connect(v) values (?)", params: [9])
    score = check(score, path_db.scalar("select v from from_connect") == 9)

  sqlite3.memory() |db|:
    query_probe = QueryProbe()
    db.instrument_queries!(query_probe)
    probed = db.scalar("select ?", params: [42])
    db.instrument_queries!(null)
    score = check(score, probed == 42 and query_probe.executions.count == 1 and query_probe.executions[0].sql == "select ?" and query_probe.executions[0].params[0] == 42)

    # --- schema + typed values ------------------------------------------
    db.exec("create table users(id integer primary key, name text, age integer, data blob)")
    score = check(score, db.json_available?())

    # execute with positional params, command result
    r = db.execute("insert into users(name, age) values (?, ?)", params: ["Ada", 36])
    score = check(score, r[:affected_rows] == 1 and r[:last_insert_id] == 1)

    # execute with named params via a prepared statement
    db.prepare("insert into users(name, age) values (:name, :age)") |st|:
      st.execute(params: {name: "Iris", age: 41})
      st.execute(params: {name: "June", age: 29})

    # --- query shapes ---------------------------------------------------
    rows = db.query("select id, name, age from users order by id")
    score = check(score, rows.count() == 3)
    # name-indifferent row map: symbol and string keys both work
    score = check(score, rows[0][:name] == "Ada" and rows[0]["age"] == 36)

    one = db.query_one("select name from users where id = ?", params: [2])
    score = check(score, one[:name] == "Iris")

    missing = db.query_one("select name from users where id = ?", params: [999], default: :none)
    score = check(score, missing == :none)

    count = db.scalar("select count(*) from users")
    score = check(score, count == 3)

    # duplicate column labels -> query_arrays
    dup = db.query_arrays("select id, id from users where id = 1")
    score = check(score, dup[:columns].count() == 2 and dup[:rows][0][0] == 1)

    # streaming each
    seen = [0]
    n = db.each("select age from users") |row|:
      seen[0] = seen[0] + row[:age]
    score = check(score, n == 3 and seen[0] == 106)

    # --- transactions ---------------------------------------------------
    db.transaction(mode: :immediate) |tx|:
      tx.execute("insert into users(name, age) values (?, ?)", params: ["Kay", 50])
    score = check(score, db.scalar("select count(*) from users") == 4)

    # rollback on exception
    before = db.scalar("select count(*) from users")
    rolled = 0
    try:
      db.transaction() |tx|:
        tx.execute("insert into users(name, age) values (?, ?)", params: ["Ghost", 1])
        raise ValueError("abort")
    rescue ValueError |e|:
      rolled = 1
    score = check(score, rolled == 1 and db.scalar("select count(*) from users") == before)

    # savepoint nesting
    db.transaction() |tx|:
      tx.savepoint() |sp|:
        sp.execute("update users set age = age + 1 where name = ?", params: ["Ada"])
    score = check(score, db.scalar("select age from users where name = ?", params: ["Ada"]) == 37)

    execute_row_error = 0
    try:
      db.execute("select 1")
    rescue Sqlite3.StepError |e|:
      execute_row_error = 1
    score = check(score, execute_row_error == 1)

    nested_mode_error = 0
    try:
      db.transaction() |tx|:
        tx.transaction(mode: :immediate) |inner|:
          inner.execute("select 1")
    rescue Sqlite3.TransactionError |e|:
      nested_mode_error = 1
    score = check(score, nested_mode_error == 1)

    # --- convenience: insert -------------------------------------------
    db.exec("create table t(a text, b text)")
    db.insert(:t, columns: [:a, :b], values: [
      ["x1", "y1"],
      ("x2", "y2"),
      {a: "x3", b: "y3"}
    ])
    score = check(score, db.scalar("select count(*) from t") == 3)

    # insert with returning
    ret = db.insert(:users, columns: [:name, :age], values: [["Leo", 22]], returning: [:id, :name])
    score = check(score, ret.count() == 1 and ret[0][:name] == "Leo")

    # insert_or_replace / upsert alias
    db.exec("create table k(id integer primary key, v text)")
    db.insert(:k, columns: [:id, :v], values: [[1, "one"]])
    db.upsert(:k, columns: [:id, :v], values: [[1, "ONE"]])
    score = check(score, db.scalar("select v from k where id = 1") == "ONE")

    # --- convenience: select / get / update / delete -------------------
    picked = db.select(:users, columns: [:id, :name], where: {name: "Iris"})
    score = check(score, picked.count() == 1 and picked[0][:name] == "Iris")

    older = db.select(:users, where: {age: [36, 37, 41]}, order: [[:age, :desc]])
    score = check(score, older.count() >= 2 and older[0][:age] >= older[1][:age])

    db.exec("create table flags(ok integer)")
    db.insert(:flags, columns: [:ok], values: [[false], [true]])
    off = db.select(:flags, where: {ok: false})
    score = check(score, off.count() == 1)

    got = db.get(:users, where: {name: "June"})
    score = check(score, got[:age] == 29)

    upd = db.update(:users, set: {age: 30}, where: {name: "June"})
    score = check(score, upd[:affected_rows] == 1 and db.scalar("select age from users where name = ?", params: ["June"]) == 30)

    deleted = db.delete(:users, where: {name: "Leo"})
    score = check(score, deleted[:affected_rows] == 1)

    # --- fragments + identifiers ---------------------------------------
    frag = fragment("select id, name, age from users where age > ?", [30])
    adults = db.query(frag)
    score = check(score, adults.count() >= 1)

    threshold = 30
    tagged = db.query(sql"""
      select id, name, age
      from users
      where age > #{threshold}
      order by id
      """)
    score = check(score, tagged.count() == 3 and tagged[0][:name] == "Ada")

    tagged_count = db.select(:users,
      columns: [sql"""
        count(*) as n
        """],
      where: sql"""
        age > #{threshold}
        """
    )
    score = check(score, tagged_count[0][:n] == 3)

    counts = db.select(:users, columns: [:name, fragment("length(name) as nlen")], where: {name: "Ada"})
    score = check(score, counts[0]["nlen"] == 3)

    score = check(score, quote_identifier(:users) == "\"users\"" and quote_identifier([:main, "tab\"le"]) == "\"main\".\"tab\"\"le\"")

    # --- error surface --------------------------------------------------
    caught = 0
    try:
      db.execute("insert into users(id, name) values (?, ?)", params: [1, "dup"])
    rescue Sqlite3.ConstraintError |e|:
      caught = 1
    score = check(score, caught == 1)

  score

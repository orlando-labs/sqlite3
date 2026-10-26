package sqlite3.transaction_selftest

import sqlite3
import task

export main

def check(value, message):
  raise ValueError("SQLite transaction: " + message) unless value

def returned(db):
  db.transaction:
    db.execute("insert into entries values (7)")
    return (:returned)

def main():
  sqlite3.memory() |db|:
    db.exec("create table entries(value integer)")
    result = db.transaction:
      db.execute("insert into entries values (1)")
      break :accepted
    check(result == :accepted and db.scalar("select count(*) from entries") == 1, "break commits")
    returned_value = returned(db)
    check(returned_value == :returned and db.scalar("select count(*) from entries") == 2, "return commits")
    result = db.transaction:
      db.execute("insert into entries values (2)")
      db.rollback()
      check(db.rollback_only?() and db.in_transaction?(), "rollback retains transaction until exit")
      db.execute("insert into entries values (3)")
      :continued
    check(result == :continued and db.scalar("select count(*) from entries") == 2, "rollback does not exit")
    db.transaction(mode: :immediate):
      check(db.transaction_mode() == :immediate, "mode available while active")
      db.transaction(mode: :immediate):
        db.execute("insert into entries values (4)")
        db.rollback() then break :discard
      db.execute("insert into entries values (5)")
    check(db.scalar("select count(*) from entries") == 3 and db.scalar("select count(*) from entries where value=4") == 0,
      "nested writer savepoint rolls back independently")
    check(db.transaction_mode() == null and not db.rollback_only?() and not db.in_transaction?(), "scope state restored")
    caught = false
    try:
      db.rollback()
    rescue Sqlite3.TransactionError:
      caught = true
    check(caught, "rollback outside managed transaction rejected")
    caught = false
    try:
      db.transaction:
        db.execute("insert into entries values (6)")
        raise ValueError("abort")
    rescue ValueError:
      caught = true
    check(caught and db.scalar("select count(*) from entries") == 3, "exception rollback")
    db.savepoint:
      db.execute("insert into entries values (8)")
      db.rollback() then break
    check(db.scalar("select count(*) from entries") == 3, "standalone savepoint rollback")

    db.pragma!(:foreign_keys, true)
    db.exec("create table parent(id integer primary key)")
    db.exec("create table child(parent_id integer references parent(id) deferrable initially deferred)")
    caught = false
    try:
      db.transaction:
        db.execute("insert into child values (999)")
    rescue Sqlite3.ConstraintError:
      caught = true
    check(caught and not db.in_transaction?() and db.scalar("select count(*) from child") == 0,
      "commit failure rolls back and propagates")

  print "PASS sqlite3 transactions"
  0

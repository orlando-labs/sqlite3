package sqlite3.backup_selftest
import sqlite3
export main

def check(value, message):
  raise ValueError(message) unless value

def main():
  sqlite3.memory() |source|:
    source.exec("CREATE TABLE sample(id INTEGER PRIMARY KEY, value TEXT); INSERT INTO sample VALUES(1,'snapshot')")
    sqlite3.memory() |destination|:
      source.backup_into(destination)
      check(destination.scalar("SELECT value FROM sample") == "snapshot", "backup transfers schema and rows")
      source.exec("UPDATE sample SET value='changed'")
      check(destination.scalar("SELECT value FROM sample") == "snapshot", "backup is isolated")
      rejected = false
      try:
        source.backup_into(source)
      rescue sqlite3.TransactionError:
        rejected = true
      check(rejected, "backup rejects same connection")
      source.transaction |transaction|:
        rejected = false
        try:
          transaction.backup_into(destination)
        rescue sqlite3.TransactionError:
          rejected = true
        check(rejected, "backup rejects active transaction")
  true

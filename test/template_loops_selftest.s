package app.sql_loops
import sqlite3
from sqlite3 import sql
export main

def check(value, message):
  raise ValueError("SQL loops: " + message) unless value

def main():
  values = ["safe", "x OR 1=1 --"]
  query = sql"""
    SELECT value FROM items WHERE 0
    %for value in values:
      OR value = #{value}
    """
  check(query.text == "SELECT value FROM items WHERE 0\nOR value = ?\nOR value = ?\n", "SQL text")
  check(query.params == values, "values remain bound parameters")
  db = sqlite3.memory()
  try:
    db.execute("CREATE TABLE items (value TEXT)")
    values.each |value|: db.execute("INSERT INTO items VALUES (?)", params: [value])
    rows = db.query(query)
    check(rows.count == 2, "one real parameterized query")
  ensure:
    db.close!
  print "PASS SQLite SQL loops"
  true

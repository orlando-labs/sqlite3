package sqlite3.pool_example

import sqlite3
import task

export main

def main():
  sqlite3.memory_pool(name: "pool_example", min_size: 1, max_size: 4) |pool|:
    pool.exec("create table users(id integer primary key, name text)")

    ada = task.spawn:
      pool.insert(:users, columns: [:name], values: [["Ada"]])
    iris = task.spawn:
      pool.insert(:users, columns: [:name], values: [["Iris"]])
    ada.wait()
    iris.wait()

    pool.transaction(mode: :immediate):
      # Pool calls in this logical task resolve to the transaction lease.
      pool.insert(:users, columns: [:name], values: [["June"]])

    pool.scalar("select count(*) from users")

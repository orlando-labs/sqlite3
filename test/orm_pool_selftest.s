package sqlite3.orm_pool_selftest

import orm
import sqlite3
from orm.sqlite3 import adapter as sqlite_adapter

export main

EXPECTED = 4

def check(score, condition):
  if condition then score + 1 else score

def main():
  score = 0

  sqlite3.memory_pool(name: "sqlite3_sputnik_orm_pool", min_size: 1, max_size: 3) |pool|:
    pool.exec("create table users(id integer primary key, email text not null, age integer)")

    User = orm.model(name: :User, table: :users)
    score = check(score, User.bind!(sqlite_adapter(pool)).ok?)

    user = User.create(email: "pool@example.test", age: 36).or_raise
    score = check(score, user.persisted? and user[:id] == 1)
    score = check(score, User.find(user[:id]).or_raise[:email] == "pool@example.test")

    rolled_back = false
    try:
      pool.transaction(mode: :immediate) |tx|:
        # The model remains bound to adapter(pool); task-local routing makes
        # its operation part of the current transaction automatically.
        User.create(email: "rollback@example.test", age: 20).or_raise
        raise ValueError("abort ORM transaction")
    rescue ValueError |e|:
      rolled_back = true
    score = check(score,
      rolled_back and
      pool.scalar("select count(*) from users where email = 'rollback@example.test'") == 0)

  score

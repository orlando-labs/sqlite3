The registry reference is `slowpilot/sqlite3`.

Build the current SDK first, then run:

```sh
python3 release/prepare.py release/package.json
```

Set `SPUTNIK_ROOT` when the SDK checkout is not the sibling `sputnik-lang`.
The recipe creates publisher-scoped imports, exact package dependencies and
relocatable archives. `--modules bytecode` is supported for modules without
exported macros; mixed variants retain macro provider sources. Native packages
also support `--native prebuilt` on a tested target. Outputs are verified before
publication. Caches, credentials and interpreter installations are excluded.

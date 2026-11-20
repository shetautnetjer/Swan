#!/usr/bin/env bash
# The table hash of docs/rust-port.md: for one map, the schema and every
# table, in a fixed order, each as "<name> <rows> <sha256 of its rows>".
# Two maps hold the same rows when this prints the same lines for both.
#
#   scripts/port-tables.sh <swan.db>
#
# Rows are read in rowid order with the rowid, so the order rows were
# written in counts too. Left out: the two meta rows that are the time the
# map was written (built_at, refreshed_at).
set -euo pipefail
db=${1:?usage: port-tables.sh <swan.db>}
[ -f "$db" ] || { echo "port-tables: no map at $db" >&2; exit 2; }
q() { sqlite3 -readonly "$db" ".mode quote" "$1"; }

printf 'schema %s %s\n' \
    "$(q "select count(*) from sqlite_master")" \
    "$(q "select type, name, tbl_name, sql from sqlite_master order by type, name" | sha256sum | cut -d' ' -f1)"
for table in $(sqlite3 -readonly "$db" "select name from sqlite_master where type = 'table' order by name"); do
    where=""
    [ "$table" = meta ] && where="where key not in ('built_at', 'refreshed_at')"
    printf '%s %s %s\n' "$table" \
        "$(q "select count(*) from \"$table\" $where")" \
        "$(q "select rowid, * from \"$table\" $where order by rowid" | sha256sum | cut -d' ' -f1)"
done

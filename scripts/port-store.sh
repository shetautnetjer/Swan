#!/usr/bin/env bash
# Stage 1 of docs/rust-port.md, the store: the Goose program and the Rust
# port are given the same flattened SCIP rows and must write the same map,
# refuse the same calls and give the same answers.
#
#   scripts/port-store.sh <flattened-dir> [repo-root]
#
# <flattened-dir> holds symbols.tsv, extents.tsv, occurrences.tsv and
# relationships.tsv (a map folder does). It and the repo are only read.
#
# 1. index      both programs; table hashes compared (scripts/port-tables.sh)
# 2. refresh    the rows with some files changed and some gone, the same
#               rows again, then the first rows again; table hashes each time.
#               Then index from rows with no relationships.tsv.
# 3. refusals   calls both must refuse: no map, no folder, not a map,
#               another schema, a second writer, a linked map, rows that are
#               not rows
# 4. freshness  (with a repo-root) a copy of some of the repo's files, with
#               files edited since the SCIP run, files gone and files added,
#               and diagnostics from before the edits: the map, and what each
#               program says is stale or new
# 5. query      every kind but `pattern` (stage 3), on names, files and
#               positions taken from the map. Both programs read the map the
#               Goose program wrote, and the bytes are compared.
#
# Each comparison is scripts/port-compare.sh: output, error text and exit
# code. SWAN_OLD and SWAN_NEW as there. PORT_JOBS: questions asked at once
# (default: the processors, 32 at most). PORT_KEEP=1 keeps the work folder.
# PORT_SLOW=<ms>: after each set of questions, how long each kind took in
# each program (median, 95th of a hundred, longest) and the questions the
# Goose program took longer than <ms> over. Ask few at once for this
# (PORT_JOBS=8): programs that share processors slow each other.
# Exit 0: all the same. 1: something differed (each difference is printed).
#
# scripts/port-prove.py shows each step here failing on a program broken on
# purpose. A step added here gets a break added there.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
src=${1:?usage: port-store.sh <flattened-dir> [repo-root]}
src=$(cd "$src" && pwd) || exit 2
root=${2:-}
if [ -n "$root" ]; then root=$(cd "$root" && pwd) || exit 2; fi
for f in symbols.tsv extents.tsv occurrences.tsv; do
    [ -f "$src/$f" ] || { echo "port-store: no $f in $src" >&2; exit 2; }
done
jobs=${PORT_JOBS:-$(nproc)}
[ "$jobs" -le 32 ] || jobs=32
old=${SWAN_OLD:-}
if [ -z "$old" ]; then
    if [ -x "$HOME/.local/share/swan/current/bin/swan" ]; then old="$HOME/.local/share/swan/current/bin/swan"; else old="$here/bin/swan"; fi
fi
# A path given from the repository is one wherever this was started from, as
# port-compare.sh takes it: the Goose program is also run here directly.
case "$old" in /*) ;; *) old="$here/$old" ;; esac
[ -x "$old" ] || { echo "port-store: no Goose program at $old" >&2; exit 2; }

work=$(mktemp -d)
if [ "${PORT_KEEP:-}" = 1 ]; then echo "work folder: $work"; else trap 'rm -rf "$work"' EXIT; fi
each="$work/each"       # the Goose program works in each/old, the Rust one in each/new
mkdir -p "$each/old" "$each/new"
bad=0
sep=$'\x1f'

# both <what> <swan arguments...>: one command, both programs, each in its
# own folder. A difference is printed and counted.
both() {
    local what=$1; shift
    local said
    said=$(PORT_EACH_IN="$each" "$here/scripts/port-compare.sh" "$@" 2>&1); local code=$?
    if [ $code != 0 ]; then
        bad=$((bad + 1))
        echo "DIFFERENT ($what): swan $*"
        printf '%s\n' "$said" | head -12 | cut -c1-300 | sed 's/^/    /'
    fi
    return $code
}

# tables <what> [map name]: the two programs' maps, by table hash.
tables() {
    local what=$1 name=${2:-swan.db}
    "$here/scripts/port-tables.sh" "$each/old/$name" >"$work/old.tables"
    "$here/scripts/port-tables.sh" "$each/new/$name" >"$work/new.tables"
    if cmp -s "$work/old.tables" "$work/new.tables"; then
        echo "$what: the same tables ($(awk '{print $1 " " $2}' "$work/old.tables" | paste -sd, | sed 's/,/, /g'))"
    else
        bad=$((bad + 1))
        echo "$what: TABLES DIFFER (Goose < > Rust)"
        diff "$work/old.tables" "$work/new.tables"
    fi
}

# A question is its arguments on one line, a unit separator between them.
question() { local IFS=$sep; printf '%s\n' "$*" >>"$questions"; }

# ask_all <map> <what>: every question in $questions, of both programs, many
# at once. Says how many were asked and prints the first differences.
ask_all() {
    python3 - "$here/scripts/port-compare.sh" "$1" "$questions" "$jobs" "$2" "${PORT_SLOW:-}" <<'ASK'
import os, statistics, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

compare, map_, listed, jobs, what, slow = sys.argv[1], sys.argv[2].encode(), sys.argv[3], int(sys.argv[4]), sys.argv[5], sys.argv[6]
asked = [line.rstrip(b"\n").split(b"\x1f") for line in open(listed, "rb") if line != b"\n"]
times = listed + ".times"
env = dict(os.environ, PORT_TIMES=times) if slow else None
if slow and os.path.exists(times):
    os.remove(times)

def ask(q):
    p = subprocess.run([compare, b"query", map_] + q, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    return q, p.returncode, p.stdout

def say_times():
    rows = []       # (goose ms, rust ms, kind, the question)
    for line in open(times, "rb"):
        old_ms, new_ms, args = line.rstrip(b"\n").split(b"\t", 2)
        a = args.split(b"\x1f")
        rows.append((int(old_ms), int(new_ms), a[2].decode(), b" ".join(a[2:]).decode("utf-8", "replace")))
    def three(xs):
        xs = sorted(xs)
        return f"{statistics.median(xs):,.0f} / {xs[min(len(xs) - 1, len(xs) * 95 // 100)]:,} / {xs[-1]:,}"
    print(f"{what}: milliseconds a question took (median / 95th of a hundred / longest):")
    print(f"    {'kind':10} {'asked':>6}   {'Goose':>24}   {'Rust':>24}")
    for kind in sorted({r[2] for r in rows}, key=lambda k: -max(r[0] for r in rows if r[2] == k)):
        of = [r for r in rows if r[2] == kind]
        print(f"    {kind:10} {len(of):6}   {three([r[0] for r in of]):>24}   {three([r[1] for r in of]):>24}")
    over = sorted((r for r in rows if r[0] > int(slow)), reverse=True)
    print(f"{what}: {len(over)} of {len(rows)} questions took the Goose program over {int(slow):,} ms" + (", the longest:" if over else ""))
    for old_ms, new_ms, kind, q in over[:25]:
        print(f"    {old_ms:8,} ms (Rust {new_ms:,})  {q[:150]}")

bad = 0
with ThreadPoolExecutor(jobs) as pool:
    for q, code, said in pool.map(ask, asked):
        if code == 0:
            continue
        bad += 1
        if bad <= 15:
            sys.stdout.buffer.write(b"DIFFERENT (" + what.encode() + b"): swan query <map> " + b" ".join(q) + b"\n")
            for line in said.split(b"\n")[:8]:
                sys.stdout.buffer.write(b"    " + line[:300] + b"\n")
sys.stdout.flush()
print(f"{what}: {len(asked)} questions asked of both programs, {bad} answered differently")
if slow:
    say_times()
sys.exit(1 if bad else 0)
ASK
    [ $? = 0 ] || bad=$((bad + 1))
}

# The questions about names: each kind, on a name, and on its whole path
# with its file.
about_names() {     # reads "name<sep>name_path<sep>file" lines
    local name path file kind
    while IFS=$sep read -r name path file; do
        [ -n "$name" ] || continue
        for kind in symbol refs uses callers callees impls hierarchy diag; do
            question "$kind" "$name"
            [ -z "$path" ] || question "$kind" "/$path" "$file"
        done
        [ -z "$path" ] || question symbol "$path"
    done
}

rootarg=()
[ -z "$root" ] || rootarg=("$root")

# ---- 1. index ----
both index index "$src" swan.db "${rootarg[@]}"
tables "index"

# ---- 2. refresh ----
# A changed copy of the rows: every 7th file loses its rows (a file that is
# gone), and in every 5th of the rest the occurrences move down a line (a
# file that was edited). Which files: by their order in occurrences.tsv.
mkdir "$work/rows"
cut -f2 "$src/occurrences.tsv" | awk '!seen[$0]++' >"$work/files.txt"
awk 'NR % 7 == 0' "$work/files.txt" >"$work/gone.txt"
awk 'NR % 7 != 0' "$work/files.txt" | awk 'NR % 5 == 0' >"$work/edited.txt"
for f in symbols.tsv extents.tsv relationships.tsv occurrences.tsv; do
    [ -f "$src/$f" ] || continue
    if [ "$f" = symbols.tsv ]; then ln -s "$src/$f" "$work/rows/$f"; continue; fi
    awk -F'\t' -v OFS='\t' -v name="$f" '
        FILENAME == ARGV[1] { gone[$0] = 1; next }
        FILENAME == ARGV[2] { edited[$0] = 1; next }
        ($2 in gone) { next }
        name == "occurrences.tsv" && ($2 in edited) { $3 += 1; $5 += 1 }
        { print }' "$work/gone.txt" "$work/edited.txt" "$src/$f" >"$work/rows/$f"
done
[ -f "$src/index.scip" ] && touch -r "$src/index.scip" "$work/rows/index.scip"
[ -f "$src/scip-started" ] && touch -r "$src/scip-started" "$work/rows/scip-started"
touch -r "$src/occurrences.tsv" "$work/rows/occurrences.tsv"
both "refresh, changed rows" refresh "$work/rows" swan.db "${rootarg[@]}"
tables "refresh ($(wc -l <"$work/gone.txt") files gone, $(wc -l <"$work/edited.txt") edited)"
both "refresh, nothing changed" refresh "$work/rows" swan.db
tables "refresh again (nothing changed)"
both "refresh, the rows as they were" refresh "$src" swan.db "${rootarg[@]}"
tables "refresh back to the first rows"
# The rows without relationships.tsv, as rows flattened before it existed.
mkdir "$work/norel"
for f in symbols.tsv extents.tsv occurrences.tsv; do ln -s "$src/$f" "$work/norel/$f"; done
both "index, no relationships.tsv" index "$work/norel" norel.db "${rootarg[@]}"
tables "index with no relationships.tsv" norel.db

# ---- 3. refusals ----
refused=0
refuse() { refused=$((refused + 1)); both "$@"; }
refuse "refresh with no map" refresh "$src" none.db
refuse "index with no rows" index "$work/no-such-rows" x.db
refuse "index into a folder that is not there" index "$src" no-such-folder/x.db
refuse "a question of no map" query none.db symbol x
for d in old new; do
    printf 'this is not a map\n' >"$each/$d/text.db"
    cp "$each/$d/swan.db" "$each/$d/schema8.db"
    sqlite3 "$each/$d/schema8.db" "update meta set value = '8' where key = 'schema_version'"
    ln -s swan.db "$each/$d/link.db"
done
refuse "a question of a file that is not a map" query text.db info x
refuse "refresh of a file that is not a map" refresh "$src" text.db
refuse "a question of a map of another schema" query schema8.db symbol x
refuse "refresh of a map of another schema" refresh "$src" schema8.db
refuse "index through a link to the map" index "$src" link.db
refuse "a question of an unknown kind" query swan.db nonsense x
# A second writer: the first is flock(1), holding each map's lock file.
holders=()
for d in old new; do
    flock -n "$each/$d/busy.db.lock" sleep 30 &
    holders+=($!)
done
sleep 0.3
refuse "index while another writer holds the map" index "$src" busy.db
kill "${holders[@]}" 2>/dev/null; wait "${holders[@]}" 2>/dev/null
# Rows that are not rows. A row with too few fields stops the Goose program
# at its own bounds check, whose words are not carried over: for those two,
# only that both refuse (and the exit code) is compared.
mkdir "$work/short" "$work/shorter" "$work/nan"
for d in short shorter nan; do printf 'a b c d x/y#\tx\t0\t\tsig\n' >"$work/$d/symbols.tsv"; : >"$work/$d/extents.tsv"; done
printf 'a b c d x/y#\n' >"$work/short/occurrences.tsv"
printf 'a b c d x/y#\tf.rs\t1\t2\t3\n' >"$work/shorter/occurrences.tsv"
printf 'a b c d x/y#\tf.rs\tone\t2\t3\t4\tdef\n' >"$work/nan/occurrences.tsv"
PORT_ERR=any refuse "a row with one field" index "$work/short" rows.db
PORT_ERR=any refuse "a row with five fields" index "$work/shorter" rows.db
refuse "a line number that is not a number" index "$work/nan" rows.db
echo "refusals: $refused calls both programs must refuse"

# ---- 4. freshness ----
if [ -n "$root" ]; then
    fresh="$work/fresh"
    mkdir -p "$fresh/repo" "$fresh/rows"
    for f in symbols.tsv extents.tsv relationships.tsv occurrences.tsv; do
        [ -f "$src/$f" ] && ln -s "$src/$f" "$fresh/rows/$f"
    done
    # The SCIP run "was" an hour ago. About sixty of the map's files are
    # copied, written before it; every third of them is then edited after
    # it. The map's other files are not there at all.
    ran=$(($(date +%s) - 3600))
    touch -d "@$ran" "$fresh/rows/scip-started"
    total=$(sqlite3 -readonly "$each/old/swan.db" "select count(*) from files where rows > 0")
    stride=$((total / 60 + 1))
    sqlite3 -readonly "$each/old/swan.db" "select file from files where rows > 0 order by file" |
        awk -v s=$stride 'NR % s == 0' >"$fresh/picked.txt"
    : >"$fresh/copied.txt"
    while IFS= read -r f; do
        [ -f "$root/$f" ] || continue
        mkdir -p "$fresh/repo/$(dirname "$f")"
        cp -- "$root/$f" "$fresh/repo/$f"
        touch -d "@$((ran - 1000))" "$fresh/repo/$f"
        printf '%s\n' "$f" >>"$fresh/copied.txt"
    done <"$fresh/picked.txt"
    awk 'NR % 3 == 0' "$fresh/copied.txt" >"$fresh/edited.txt"
    while IFS= read -r f; do touch -d "@$((ran + 1000))" "$fresh/repo/$f"; done <"$fresh/edited.txt"
    # Files added since: ones a walk must list, and ones it must not (an
    # ending the map has no files for, hidden and dependency folders, a
    # folder git ignores, a linked folder, a file older than the SCIP run).
    first=$(head -1 "$fresh/copied.txt")
    ext=".${first##*.}"
    r="$fresh/repo"
    mkdir -p "$r/sub dir" "$r/.hidden" "$r/node_modules" "$r/ignored_dir" "$r/deep/ignored" "$r/deep/kept"
    for f in "brand_new$ext" "sub dir/also new$ext" "deep/kept/z$ext" ".dotfile$ext" \
             notes.swan-port-no-such-ending NOENDING .only_dot_start \
             ".hidden/x$ext" "node_modules/x$ext" "ignored_dir/x$ext" "deep/ignored/y$ext"; do
        printf 'added\n' >"$r/$f"
    done
    printf 'added\n' >"$r/old_new$ext"; touch -d "@$((ran - 1000))" "$r/old_new$ext"
    ln -s "sub dir" "$r/linkdir"
    printf 'ignored_dir\ndeep/ignored\n' >"$fresh/rows/git-ignored.txt"

    both "freshness: index" index "$fresh/rows" fresh.db "$fresh/repo"
    tables "freshness: index" fresh.db
    # Files Swan "edited" itself, in both maps: the first four edited files
    # get an edit time. Its own mtime and no mark (a map from before marks):
    # not stale. Its own mtime and a mark that is not its text: stale.
    # Another time: stale. Its own mtime and a mark too short to be one: not
    # stale. (A mark that matches is stage 6: only an edit makes one.)
    n=0
    while IFS= read -r f; do
        n=$((n + 1))
        [ $n -le 4 ] || break
        m=$(stat -c '%.9Y' "$r/$f" | tr -d .)
        esc=${f//\'/\'\'}
        case $n in
            1) sql="update files set edited_mtime = $m where file = '$esc'" ;;
            2) sql="update files set edited_mtime = $m, hash = 'e1' where file = '$esc'" ;;
            3) sql="update files set edited_mtime = $m + 1 where file = '$esc'" ;;
            4) sql="update files set edited_mtime = $m, hash = 'e' where file = '$esc'" ;;
        esac
        sqlite3 "$each/old/fresh.db" "$sql"
        sqlite3 "$each/new/fresh.db" "$sql"
    done <"$fresh/edited.txt"

    # Diagnostics, "checked" between the two times: the Goose program loads
    # made-up ones into its map (the one both are asked about) from a file
    # dated after the copies and before the edits, so one in an edited file
    # is stale and one in an untouched file is not.
    fmap="$each/old/fresh.db"
    mkdir "$fresh/diag"
    sqlite3 -readonly "$fmap" -separator $'\t' -cmd "create temp table there (file text)" -cmd ".import '$fresh/copied.txt' there" "
        select def_file, def_line, def_col, def_line, def_col + 1,
               case when id % 3 = 0 then 'error' else 'warning' end, 'port', 'P' || (id % 9), 'made up'
        from symbols where in_repo = 1 and def_file in (select file from there) and id % 2 = 0 limit 3000" >"$fresh/diag/diagnostics.tsv"
    touch -d "@$((ran - 500))" "$fresh/diag/diagnostics.tsv"
    "$old" diagnostics "$fresh/diag" "$fmap" >/dev/null || { echo "port-store: the Goose program could not load diagnostics" >&2; exit 2; }

    questions="$work/fresh-questions.txt"; : >"$questions"
    question info x
    question overview ""
    question unused ""
    question diagfile ""
    # Every copied file (edited or not) and as many that are gone.
    { cat "$fresh/copied.txt"; grep -v -x -F -f "$fresh/copied.txt" "$fresh/picked.txt" 2>/dev/null; sqlite3 -readonly "$fmap" "select file from files where rows > 0 order by file" | awk -v s=$stride 'NR % s == 1'; } |
        awk '!seen[$0]++' >"$fresh/asked-files.txt"
    while IFS= read -r f; do
        esc=${f//\'/\'\'}
        question overview "$f"
        question diagfile "$f"
        sqlite3 -readonly "$fmap" -separator "$sep" "
            select name, name_path, def_file from symbols
            where def_file = '$esc' and in_repo = 1 and kind not in ('parameter', 'type_parameter') and name != ''
              and name not like '%' || char(10) || '%' order by id limit 1" | about_names
        while IFS=$sep read -r line col; do
            [ -n "$line" ] && question at "$f:$((line + 1)):$((col + 1))"
        done < <(sqlite3 -readonly "$fmap" -separator "$sep" "select start_line, start_col from occurrences where file = '$esc' order by rowid limit 2")
    done <"$fresh/asked-files.txt"
    said=$(sqlite3 -readonly "$fmap" "select count(*) from files")
    ask_all "$fmap" "freshness ($(wc -l <"$fresh/copied.txt") of $said files there, $(wc -l <"$fresh/edited.txt") edited since, 4 files added)"
    # What the Goose program itself counted, so the scenario is seen to be one.
    (cd "$each/old" && "$old" query fresh.db info x) | grep -o '"stale_file_count":[0-9]*\|"new_file_count":[0-9]*' | paste -sd' ' | sed 's/^/freshness: the Goose program says /'
    echo "freshness: of $(wc -l <"$fresh/diag/diagnostics.tsv") diagnostics it calls $( (cd "$each/old" && "$old" query fresh.db diagfile "") | grep -o '"stale":true' | wc -l) stale (of the 200 it lists)"
fi

# ---- 5. query ----
# Both programs read the map the Goose program wrote. Diagnostics are loaded
# into it by the Goose program (`swan diagnostics` is stage 6), from rows
# made up here: one on the first line of every 11th symbol. Before that, the
# answer of a map with none is compared (and in the freshness map above).
map="$each/old/swan.db"
questions="$work/before-questions.txt"; : >"$questions"
question diag x
question diagfile ""
question diagfile no/such/file
ask_all "$map" "query, before diagnostics are loaded"
mkdir "$work/diag"
sqlite3 -readonly "$map" -separator $'\t' "
    select def_file, def_line, def_col, def_line, def_col + 1,
           case when id % 3 = 0 then 'error' else 'warning' end, 'port', 'P' || (id % 9), 'made up for ' || replace(replace(name, char(10), ' '), char(9), ' ')
    from symbols where in_repo = 1 and def_file is not null and id % 11 = 0 limit 400" >"$work/diag/diagnostics.tsv"
"$old" diagnostics "$work/diag" "$map" >/dev/null || { echo "port-store: the Goose program could not load diagnostics" >&2; exit 2; }

questions="$work/questions.txt"; : >"$questions"
question info x
question unused ""
question diagfile ""
# Names: every 13th symbol of the repo, by name and by name path, alone and
# with its file; the names most symbols share (ambiguous ones); the classes
# other symbols implement; and names that match nothing.
sqlite3 -readonly "$map" -separator "$sep" "
    select name, name_path, def_file from symbols
    where in_repo = 1 and kind not in ('parameter', 'type_parameter') and name != ''
      and name not like '%' || char(10) || '%' and id % 13 = 0 order by id limit 60" | about_names
sqlite3 -readonly "$map" -separator "$sep" "
    select name, '', '' from (select name, count(*) n from symbols where in_repo = 1 and name != '' group by name order by n desc, name limit 12)
    union
    select name, '', '' from (select name from symbols where id in (select related_id from relationships where is_impl = 1) and name != '' limit 25)" | about_names
for name in no_such_symbol_anywhere /no/such/path a/b Error IOError ""; do
    for kind in symbol refs uses callers callees impls hierarchy diag; do question "$kind" "$name"; done
done
# Files and folders: every 9th file, its folder, and ones that are not there.
while IFS= read -r file; do
    [ -n "$file" ] || continue
    question overview "$file"
    question unused "$file"
    question diagfile "$file"
    question overview "$(dirname "$file")"
    question unused "$(dirname "$file")"
done < <(sqlite3 -readonly "$map" "select file from files where rowid % 9 = 0 order by file limit 40")
question overview no/such/file.rs
question overview ""
# Positions: every 97th occurrence, on its column, just past its end, and at
# the start of its line; and positions that are not a position.
while IFS=$sep read -r file line col end; do
    [ -n "$file" ] || continue
    question at "$file:$((line + 1)):$((col + 1))"
    question at "$file:$((line + 1)):$((end + 1))"
    question at "$file:$((line + 1)):1"
done < <(sqlite3 -readonly "$map" -separator "$sep" "
    select file, start_line, start_col, end_col from occurrences where rowid % 97 = 0 and file not like '%:%' order by rowid limit 150")
question at "no/such/file.rs:1:1"
question at "x:y:z"
question at "only-two:1"
ask_all "$map" "query"

if [ $bad = 0 ]; then echo "the same: $src"; else echo "$bad differences: $src"; fi
[ $bad = 0 ]

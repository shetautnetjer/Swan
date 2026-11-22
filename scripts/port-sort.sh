#!/usr/bin/env bash
# Stage 4's comparison for sorting (docs/rust-port.md): Goose's sort and the
# Rust program's copy of it (rust/src/gsort.rs) put the same lists in the
# same order, elements that compare as equal included. Goose's sort is
# unstable, so that order is whatever its steps give, and a map holds it:
# the files of one size in a plan of TypeScript's chunks.
#
# The lists are made here, the same every run: every short list of three
# keys, lists of each length around the sort's turning points (10, 128)
# with few keys and with many, lists in order, reversed, in runs and in
# teeth, and lists made to split as badly as a list can, which is what
# takes the sort to its heapsort. Both dumpers (scripts/port-sort.goose and
# rust/src/bin/port-sort.rs) sort each and the answers are compared by
# bytes.
#
#   scripts/port-sort.sh
#
# GOOSE: the Goose compiler (as scripts/build.sh). PORT_SORT_RUST: the Rust
# dumper (default build/rust/release/port-sort).
# Prints "the same: N of N lists" or each list that differs and "DIFFERENT:
# K of N lists". Exit 0: all the same. 1: some differ. 2: a dumper is
# missing or does not build, or the lists could not be made.
set -uo pipefail
cd "$(dirname "$0")/.."
GOOSE=${GOOSE:-.tools/goose/goose-v2026.3-linux-x64/goose}
export GOOSE_HOME=${GOOSE_HOME:-$PWD/.tools/goose-home}
new=${PORT_SORT_RUST:-build/rust/release/port-sort}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p build
# Built once and kept: several comparisons at once (the prover's) must not
# build it over each other.
if [ ! -x build/port-sort-goose ] || [ scripts/port-sort.goose -nt build/port-sort-goose ]; then
    "$GOOSE" build scripts/port-sort.goose -o "$work/port-sort-goose" >"$work/build.log" 2>&1 ||
        { echo "port-sort: the Goose dumper does not build:"; tail -5 "$work/build.log"; exit 2; }
    mv "$work/port-sort-goose" build/port-sort-goose
fi
[ -x "$new" ] || { echo "port-sort: no Rust dumper at $new (cargo build --release --manifest-path rust/Cargo.toml)"; exit 2; }
old=build/port-sort-goose

# ---- the lists, one file a kind: t<number> ----
# The sort below is this script's own reading of Goose's, used for two
# things only: to make the lists that split badly (each comparison is
# answered so that the pivot chosen is the smallest left), and to count
# which of the sort's ways each list takes. What is compared is Goose's
# sort and the Rust program's; a slip here would make the lists less
# searching, and the counts printed would show it.
python3 -I - "$work" <<'PYEOF' || { echo "port-sort: the lists could not be made"; exit 2; }
import itertools
import random
import sys

work = sys.argv[1]
took = {"lists": 0, "ties": 0, "long": 0, "run": 0, "equal": 0, "heap": 0, "pivot9": 0}


def insertion(v, lo, hi, F):
    for i in range(lo + 1, hi):
        x = v[i]
        j = i
        while j > lo:
            y = v[j - 1]
            if not F(x, y):
                break
            v[j] = y
            j -= 1
        v[j] = x


def run(v, F):
    n = len(v)
    if n < 2:
        return n
    e = 2
    if F(v[1], v[0]):
        while e < n and F(v[e], v[e - 1]):
            e += 1
        v[:e] = v[:e][::-1]
    else:
        while e < n and not F(v[e], v[e - 1]):
            e += 1
    return e


def median3(v, a, b, c, F):
    x = F(v[a], v[b])
    if x != F(v[a], v[c]):
        return a
    if F(v[b], v[c]) != x:
        return c
    return b


def pivot(v, lo, hi, F, hit):
    n = hi - lo
    n8 = n // 8
    a, b, c = lo, lo + n8 * 4, lo + n8 * 7
    if n < 128:
        return median3(v, a, b, c, F)
    hit["pivot9"] = 1
    m8 = n8 // 8
    return median3(v, median3(v, a, a + m8 * 4, a + m8 * 7, F), median3(v, b, b + m8 * 4, b + m8 * 7, F),
                   median3(v, c, c + m8 * 4, c + m8 * 7, F), F)


def partition(v, lo, hi, F):
    p = v[lo]
    lt = lo + 1
    for i in range(lo + 1, hi):
        x = v[i]
        v[i] = v[lt]
        v[lt] = x
        if F(x, p):
            lt += 1
    return lt - 1 - lo


def sift_down(v, lo, n, start, F):
    i = start
    if 2 * i + 1 >= n:
        return
    x = v[lo + i]
    while True:
        l = 2 * i + 1
        if l >= n:
            break
        m = l
        if l + 1 < n and F(v[lo + l + 1], v[lo + l]):
            m = l + 1
        if not F(v[lo + m], x):
            break
        v[lo + i] = v[lo + m]
        i = m
    v[lo + i] = x


def heap(v, lo, hi, F):
    def after(a, b):
        return F(b, a)
    n = hi - lo
    for i in range(n // 2 - 1, -1, -1):
        sift_down(v, lo, n, i, after)
    for end in range(n - 1, 0, -1):
        v[lo], v[lo + end] = v[lo + end], v[lo]
        sift_down(v, lo, end, 0, after)


def gsort(v, F, hit, before_heap=None):
    n = len(v)
    if n <= 10:
        insertion(v, 0, n, F)
        return
    if run(v, F) == n:
        hit["run"] = 1
        return
    limit = 2 * (n.bit_length() - 1)
    st = []
    lo, hi = 0, n
    while True:
        size = hi - lo
        if size > 10 and limit > 0:
            limit -= 1
            p = pivot(v, lo, hi, F, hit)
            v[lo], v[p] = v[p], v[lo]
            if lo > 0 and not F(v[lo - 1], v[lo]):
                hit["equal"] = 1
                m = partition(v, lo, hi, lambda a, b: not F(b, a))
                v[lo], v[lo + m] = v[lo + m], v[lo]
                lo += m + 1
                continue
            m = partition(v, lo, hi, F)
            v[lo], v[lo + m] = v[lo + m], v[lo]
            if m < size - 1 - m:
                st += [lo + m + 1, hi, limit]
                hi = lo + m
            else:
                st += [lo, lo + m, limit]
                lo += m + 1
            continue
        if size > 10:
            hit["heap"] = 1
            if before_heap:
                before_heap()
            heap(v, lo, hi, F)
        else:
            insertion(v, lo, hi, F)
        if not st:
            return
        limit = st.pop()
        hi = st.pop()
        lo = st.pop()


def worst(n, spread=0):
    """Keys that make the sort split as badly as it can: a key is fixed only
    when a comparison needs it, and then as the smallest not yet given. The
    first three are fixed beforehand and out of order, or the list would
    come out in order and be done at a glance. With a spread, the keys not
    fixed when the heapsort starts are drawn from so many values above the
    fixed ones, so that what is heapsorted is in no order and, with a small
    spread, holds equal keys."""
    gas = 20 * n
    val = [gas] * n
    val[0], val[1], val[2] = 1, 2, 0
    state = {"solid": 3, "candidate": 0}

    def freeze(x):
        val[x] = state["solid"]
        state["solid"] += 1

    def F(x, y):
        if val[x] == gas and val[y] == gas:
            freeze(x if x == state["candidate"] else y)
        if val[x] == gas:
            state["candidate"] = x
        elif val[y] == gas:
            state["candidate"] = y
        return val[x] < val[y]

    def scatter():
        for x in range(n):
            if spread and val[x] == gas:
                val[x] = state["solid"] + rnd.randrange(spread)

    gsort(list(range(n)), F, {}, scatter)
    top = max(x for x in val if x != gas) + 1
    return [top if x == gas else x for x in val]


out = None


def put(mode, shift, keys):
    """One list, both written and counted."""
    out.write(f"{mode}{shift} " + " ".join(map(str, keys)) + "\n")
    k = [x >> shift for x in keys]
    hit = {}
    if mode == "d":
        gsort(list(range(len(k))), lambda a, b: k[a] > k[b], hit)
    else:
        gsort(list(range(len(k))), lambda a, b: k[a] < k[b], hit)
    took["lists"] += 1
    took["ties"] += len(set(k)) < len(k)
    took["long"] += len(k) > 10
    for name in hit:
        took[name] += 1


def both(keys, shift=0):
    put("a", shift, keys)
    put("d", shift, keys)


rnd = random.Random(20261122)
files = 0


def kind():
    global out, files
    if out:
        out.close()
    files += 1
    out = open(f"{work}/t{files:03d}", "w")


# Every list of up to six keys out of three, and of seven and eight out of two.
kind()
for n in range(0, 7):
    for keys in itertools.product((0, 1, 2), repeat=n):
        both(keys)
for n in (7, 8):
    for keys in itertools.product((0, 1), repeat=n):
        both(keys)
# Around ten, where insertion alone ends: few keys and many.
kind()
for n in (9, 10, 11, 12, 13):
    for spread in (1, 2, 3, 5, n, 10 * n):
        for _ in range(25):
            both([rnd.randrange(spread) for _ in range(n)])
# Lists of every length to 400, with as many keys as 1, 2, 3, 4, 8, a quarter
# of the length, the length, and ten times it.
kind()
for n in range(11, 401):
    spread = (1, 2, 3, 4, 8, n // 4 + 1, n, 10 * n)[n % 8]
    both([rnd.randrange(spread) for _ in range(n)])
    both([rnd.randrange(spread) for _ in range(n)], shift=rnd.randrange(3))
# In order, reversed, in runs and in teeth, at the lengths the sort turns on.
kind()
for n in (11, 12, 16, 17, 20, 21, 64, 100, 127, 128, 129, 200, 255, 256, 257, 500, 1000, 1024, 3000):
    up = list(range(n))
    both(up)                                              # in order, and strictly reversed
    both([x // 2 for x in up])                            # in order with pairs, and reversed with pairs
    both([x // 5 for x in up])
    both([0] * n)                                         # one key
    both([0] * (n - 1) + [1])
    both([1] + [0] * (n - 1))
    for period in (2, 3, 7, 16):
        both([x % period for x in up])                    # teeth
        both([period - x % period for x in up])
    both([min(x, n - 1 - x) for x in up])                 # a pipe, and a valley
    both([max(x, n - 1 - x) for x in up])
    for at in (0, 1, n // 2, n - 2, n - 1):               # in order but for one, and reversed but for one
        one = up[:]
        one[at] = n // 3
        both(one)
        one = up[::-1]
        one[at] = n // 3
        both(one)
    both(up[: n // 2] + up[: n - n // 2])                 # two runs
    both(up[n // 2:] + up[: n // 2])
    both(up[::-1][: n // 2] + up[: n - n // 2])
    few = [0] * n
    for _ in range(4):
        few[rnd.randrange(n)] = rnd.randrange(1, 4)
    both(few)                                             # one key but for a few
    shuffled = up[:]
    rnd.shuffle(shuffled)
    both(shuffled)
    both(shuffled, shift=1)
    both(shuffled, shift=3)
# Long lists: many keys, and few.
kind()
for n, spread in ((5000, 50), (5000, 5000), (4096, 3), (4097, 1000000), (2500, 2)):
    both([rnd.randrange(spread) for _ in range(n)])
# Lists that split as badly as a list can, as they are and with their keys
# drawn together so that some are equal; then the same with what is left to
# the heapsort in no order, of many keys and of few.
kind()
for n in (11, 12, 24, 64, 127, 128, 129, 300, 1000, 2000):
    bad = worst(n)
    top = max(bad)
    put("a", 0, bad)
    put("d", 0, [top - x for x in bad])
    for shift in (1, 2, 4):
        put("a", shift, bad)
        put("d", shift, [top - x for x in bad])
kind()
for n in (24, 25, 40, 64, 100, 127, 128, 129, 300, 301, 1000, 2000):
    for spread in (10 * n, n, n // 4, 3, 2):
        for _ in range(3):
            bad = worst(n, spread)
            top = max(bad)
            put("a", 0, bad)
            put("d", 0, [top - x for x in bad])
out.close()
print(f"lists: {took['lists']} in {files} files; longer than ten: {took['long']}; with equal keys: {took['ties']}; "
      f"already in order or reversed: {took['run']}; a pivot of nine: {took['pivot9']}; "
      f"a pass for keys equal to the pivot: {took['equal']}; heapsorted: {took['heap']}")
if min(took.values()) == 0:
    sys.exit("port-sort: one of the sort's ways is taken by no list")
PYEOF

total=0; bad=0
for f in "$work"/t*; do
    "$old" "$f" >"$work/a" 2>&1
    "$new" "$f" >"$work/b" 2>&1
    lines=$(wc -l <"$f")
    total=$((total + lines))
    if ! cmp -s "$work/a" "$work/b" || [ "$(wc -l <"$work/a")" != "$lines" ]; then
        # Each list of the file that differs, the first few shown.
        differ=$(paste "$f" "$work/a" "$work/b" | awk -F '\t' '$2 != $3 { n++; if (n <= 3) printf "DIFFERENT: %s list %d: %s\n    Goose: %s\n    Rust:  %s\n", name, NR, substr($1, 1, 60), substr($2, 1, 90), substr($3, 1, 90) } END { print n + 0 }' name="${f##*/}")
        count=$(printf '%s\n' "$differ" | tail -1)
        # The answers are not one a list (a dumper stopped): the whole file counts.
        [ "$count" = 0 ] && { count=$lines; echo "DIFFERENT: ${f##*/}: the dumpers do not answer list for list ($(wc -l <"$work/a") and $(wc -l <"$work/b") lines for $lines lists)"; }
        [ $bad -le 12 ] && printf '%s\n' "$differ" | sed '$d'
        bad=$((bad + count))
    fi
done
if [ $bad = 0 ]; then echo "the same: $total of $total lists"; exit 0; fi
echo "DIFFERENT: $bad of $total lists"
exit 1

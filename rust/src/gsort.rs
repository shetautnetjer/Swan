// Goose's sort (its standard library, stdlib/std.goose: sort and the
// sort_ helpers), carried step by step.
//
// It is unstable: which of two elements that compare as equal comes first
// is whatever these steps give, and the Goose program's answers hold that
// order. A plan of TypeScript's chunks (src/pipeline.rs, plan_ts) sorts the
// files by size, and files of one size are common; with Rust's own sorts
// they would land in other chunks than the Goose program puts them in.
//
// `f(a, b)` is "a goes before b". Every index stays in range whatever `f`
// returns, as in Goose.
//
// scripts/port-sort.sh compares it with Goose's sort.

type Before<'a, T> = &'a dyn Fn(T, T) -> bool;

/// Insertion sort. Stable: an element moves only past those it goes
/// strictly before.
fn sort_insertion<T: Copy>(v: &mut [T], f: Before<T>) {
    for i in 1..v.len() {
        let x = v[i];
        let mut j = i;
        while j > 0 {
            let y = v[j - 1];
            if !f(x, y) {
                break;
            }
            v[j] = y;
            j -= 1;
        }
        v[j] = x;
    }
}

/// The length of the run `v` starts with: elements in order, or in strictly
/// descending order, which are reversed in place so that they are in order
/// too.
fn sort_run<T: Copy>(v: &mut [T], f: Before<T>) -> usize {
    if v.len() < 2 {
        return v.len();
    }
    let mut e = 2;
    if f(v[1], v[0]) {
        while e < v.len() {
            if !f(v[e], v[e - 1]) {
                break;
            }
            e += 1;
        }
        v[..e].reverse();
    } else {
        while e < v.len() {
            if f(v[e], v[e - 1]) {
                break;
            }
            e += 1;
        }
    }
    e
}

/// The index of the median of `v[a]`, `v[b]` and `v[c]`.
fn sort_median3<T: Copy>(v: &[T], a: usize, b: usize, c: usize, f: Before<T>) -> usize {
    let x = f(v[a], v[b]);
    if x != f(v[a], v[c]) {
        return a;
    }
    // v[a] goes before both others (x) or after both: the median is the
    // first of the other two, or the last.
    if f(v[b], v[c]) != x {
        return c;
    }
    b
}

/// A pivot for `v`, at least 8 long: the median of elements at 0, 4/8 and
/// 7/8 of the way, and from 128 elements on the median of three such
/// medians, each over its own eighth of `v`.
fn sort_pivot<T: Copy>(v: &[T], f: Before<T>) -> usize {
    let n8 = v.len() / 8;
    let a = 0;
    let b = n8 * 4;
    let c = n8 * 7;
    if v.len() < 128 {
        return sort_median3(v, a, b, c, f);
    }
    let m8 = n8 / 8;
    let ma = sort_median3(v, a, a + m8 * 4, a + m8 * 7, f);
    let mb = sort_median3(v, b, b + m8 * 4, b + m8 * 7, f);
    let mc = sort_median3(v, c, c + m8 * 4, c + m8 * 7, f);
    sort_median3(v, ma, mb, mc, f)
}

/// Moves the elements x of `v[1..]` with `f(x, v[0])` to the front of
/// `v[1..]` and returns how many there are; `v[0]` is the pivot and stays.
fn sort_partition<T: Copy>(v: &mut [T], f: Before<T>) -> usize {
    let p = v[0];
    let mut lt = 1;
    for i in 1..v.len() {
        let x = v[i];
        v[i] = v[lt];
        v[lt] = x;
        lt += if f(x, p) { 1 } else { 0 };
    }
    lt - 1
}

fn sift_down<T: Copy>(xs: &mut [T], start: usize, f: Before<T>) {
    let n = xs.len();
    let mut i = start;
    if 2 * i + 1 >= n {
        return; // A leaf, or a start past the end, is not read.
    }
    let x = xs[i];
    loop {
        let l = 2 * i + 1;
        if l >= n {
            break;
        }
        let mut m = l;
        let r = l + 1;
        if r < n && f(xs[r], xs[l]) {
            m = r;
        }
        if !f(xs[m], x) {
            break;
        }
        xs[i] = xs[m];
        i = m;
    }
    xs[i] = x;
}

/// Heapsort, for ranges partitioning keeps splitting badly.
fn sort_heap<T: Copy>(v: &mut [T], f: Before<T>) {
    let after = |a: T, b: T| f(b, a);
    let mut i = v.len() / 2;
    while i > 0 {
        i -= 1;
        sift_down(v, i, &after);
    }
    let mut end = v.len();
    while end > 1 {
        end -= 1;
        v.swap(0, end);
        sift_down(&mut v[..end], 0, &after);
    }
}

/// Sorts `xs` in place as Goose's `sort(xs) { a, b => ... }` does.
pub fn goose_sort<T: Copy>(xs: &mut [T], f: Before<T>) {
    let n = xs.len();
    if n <= 10 {
        sort_insertion(xs, f);
        return;
    }
    let r = sort_run(xs, f);
    if r == n {
        return;
    }
    let mut limit: i64 = 2 * (63 - (n as u64).leading_zeros() as i64);
    let mut st: Vec<usize> = Vec::new(); // lo, hi, limit per deferred range
    let mut lo = 0;
    let mut hi = n;
    loop {
        let len = hi - lo;
        if len > 10 && limit > 0 {
            limit -= 1;
            let pivot = sort_pivot(&xs[lo..hi], f);
            xs[lo..hi].swap(0, pivot);
            if lo > 0 && !f(xs[lo - 1], xs[lo]) {
                // Nothing here goes before the pivot: the elements equal to
                // it go to the front, where they are done.
                let m = sort_partition(&mut xs[lo..hi], &|a, b| !f(b, a));
                xs[lo..hi].swap(0, m);
                lo += m + 1;
                continue;
            }
            let m = sort_partition(&mut xs[lo..hi], f);
            xs[lo..hi].swap(0, m);
            if m < len - 1 - m {
                st.push(lo + m + 1);
                st.push(hi);
                st.push(limit as usize);
                hi = lo + m;
            } else {
                st.push(lo);
                st.push(lo + m);
                st.push(limit as usize);
                lo += m + 1;
            }
            continue;
        }
        if len > 10 {
            sort_heap(&mut xs[lo..hi], f);
        } else {
            sort_insertion(&mut xs[lo..hi], f);
        }
        let (Some(l), Some(h), Some(o)) = (st.pop(), st.pop(), st.pop()) else {
            return;
        };
        limit = l as i64;
        hi = h;
        lo = o;
    }
}

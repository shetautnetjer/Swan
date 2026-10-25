# Prints a map's content keyed by SCIP symbols rather than row ids, so a
# refreshed map and a fresh build of the same rows can be compared with diff.
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
for r in c.execute("""SELECT scip, name, name_path, kind, signature, def_file, def_line, def_col,
                             body_start, body_end, in_repo FROM symbols ORDER BY scip"""):
    print("S", *r, sep="\t")
for r in c.execute("""SELECT s.scip, o.file, o.start_line, o.start_col, o.end_line, o.end_col, o.is_def, e.scip
                      FROM occurrences o JOIN symbols s ON s.id = o.symbol_id
                      LEFT JOIN symbols e ON e.id = o.enclosing_id
                      ORDER BY o.file, o.start_line, o.start_col, s.scip"""):
    print("O", *r, sep="\t")
for r in c.execute("""SELECT s.scip, t.scip, r.file, r.is_impl, r.is_ref, r.is_typedef, r.is_def
                      FROM relationships r JOIN symbols s ON s.id = r.symbol_id
                      JOIN symbols t ON t.id = r.related_id ORDER BY 1, 2"""):
    print("R", *r, sep="\t")
for r in c.execute("SELECT file, hash, rows FROM files ORDER BY file"):
    print("F", *r, sep="\t")

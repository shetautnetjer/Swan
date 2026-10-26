// Maps fixtures/tiny-rs with rust-analyzer and checks the two Rust repairs:
// trait impls recovered from rust-analyzer's symbol names, and uses inside
// nested macro calls found by name.
//
//   bun tests/rust_check.ts

const sh = (cmd: string[]) => {
  const r = Bun.spawnSync(cmd, { stdout: "pipe", stderr: "pipe" });
  if (r.exitCode !== 0) throw new Error(`${cmd.join(" ")}: ${r.stderr}`);
  return r.stdout.toString();
};
sh(["scripts/index-repo.sh", "fixtures/tiny-rs", "data/tiny-rs"]);
const q = (...a: string[]) => JSON.parse(sh(["bin/swan", "query", "data/tiny-rs/swan.db", ...a]));

let failures = 0;
const check = (what: string, ok: boolean, detail: unknown = "") => {
  console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok ? "" : `\n     ${JSON.stringify(detail)}`}`);
  if (!ok) failures++;
};

const impls = q("impls", "Area").implementations.map((s: any) => s.name_path).sort();
check("find_implementations Area: Tile and Disc", impls.join(",") === "Disc,Tile", impls);

const area = q("hierarchy", "Area/area").subtypes.map((s: any) => s.name_path).sort();
check("the trait method's implementations are Tile/area and Disc/area", area.join(",") === "Disc/area,Tile/area", area);

check("impl methods are named by their type: Tile/new", q("symbol", "Tile/new").length === 1);

const shape = q("uses", "/Shape")[0].references;
const lines = (rs: any[]) => rs.map((r: any) => r.line);
check("Shape::Square inside vec![...] counts as a use of Shape, by name",
  shape.some((r: any) => r.line === 42 && r.via === "Shape/Square" && r.by_name), shape);
check("Shape::Circle inside assert!(matches!(...)) is found too", lines(shape).includes(55), shape);

const tile = q("uses", "/Tile")[0].references;
check("Tile::new inside vec![...] counts as a use of Tile", tile.some((r: any) => r.line === 56 && r.via === "Tile/new"), tile);

console.log(failures ? `${failures} check(s) failed` : "all rust checks passed");
process.exit(failures ? 1 : 0);

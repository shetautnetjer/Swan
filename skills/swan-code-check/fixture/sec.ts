// Known-answer fixture for the Swan pattern pack. Each line ends with a tag that
// patterns.json refers to. Do not reuse in real code.
declare function execSync(cmd: string, opts?: object): string;
declare function execFileSync(cmd: string, args: string[]): string;
declare function exec(cmd: string, opts?: object): void;
declare function spawn(cmd: string, args: string[], opts?: object): void;
declare function chmodSync(p: string, mode: number): void;
declare const it: any; declare const test: any; declare const https: any;
const file = "x"; const re = /a/;
export function cases(user: string) {
  execSync(`magick "${file}" out.png`, { stdio: "ignore" }); // T01 template shell string
  execSync("pyright --version"); // T02 constant string (benign, still listed)
  execSync("rm " + user); // T03 concatenated shell string
  exec(`ls ${user}`); // T04 exec with template
  re.exec(user); // T05 RegExp.exec, not a shell
  spawn("sh", ["-c", user], { cwd: "/", shell: true }); // T06 shell: true after another option
  spawn("ls", ["-la"], { cwd: "/" }); // T07 no shell
  spawn("sh", ["-c", user], { shell: true }); // T08 shell: true as the only option
  eval(user); // T09 eval
  const f = new Function("a", user); // T10 new Function
  https.request({ host: "h", rejectUnauthorized: false }); // T11 TLS check off
  https.request({ host: "h", rejectUnauthorized: true }); // T12 TLS check on
  try { f(); } catch { } // T13 empty catch, no binding
  try { f(); } catch (e) { } // T14 empty catch, binding
  try { f(); } catch (e) { console.error(e); } // T15 handled
  const cfg = JSON.parse(user) as { a: number }; // T16 unchecked cast of parsed input
  chmodSync("/shared", 0o777); // T17 world-writable dir
  chmodSync("/mine", 0o700); // T18 private
  chmodSync("/shared2", 0o666); // T19 world-writable file
  execFileSync("ls", [user]); // T22 no shell (safe form)
  return cfg;
}
it.only("focused", () => {}); // T20 focused test
test.skip("skipped", () => {}); // T21 skipped test

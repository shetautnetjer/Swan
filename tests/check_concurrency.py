#!/usr/bin/env python3
"""Bounded Linux-only Swan concurrency experiment using disposable synthetic maps.

No build, install, indexer, live server, network request, or trust operation runs.
Every mutation is inside a newly created directory. Artifacts are retained.
Requires Python 3, Linux inotify/SIGSTOP, and an explicitly selected Swan binary.
PASS permits explicit busy/refusal preserving a complete generation. It does not
qualify seamless concurrency, power-loss durability, the full indexer pipeline,
Windows/macOS, threaded SQLite use, or the separate saved trust-list updates.
"""

import argparse
from contextlib import closing
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time


class Inconclusive(RuntimeError):
    pass


def require(value, message):
    if not value:
        raise AssertionError(message)


def child_environment():
    environment = os.environ.copy()
    # A user's opted-in warmup must not turn a storage experiment into a live
    # language-server run. This affects only harness child processes.
    environment["SWAN_WARM"] = ""
    environment.pop("SWAN_TRUST_BUILD", None)
    return environment


class Child:
    def __init__(self, argv, directory, name, timeout):
        self.argv, self.timeout = list(map(str, argv)), timeout
        self.stdout_path = directory / (name + ".stdout")
        self.stderr_path = directory / (name + ".stderr")
        self.stdout = self.stdout_path.open("wb")
        self.stderr = self.stderr_path.open("wb")
        self.process = subprocess.Popen(self.argv, stdout=self.stdout,
                                        stderr=self.stderr, start_new_session=True,
                                        env=child_environment())
        self.stopped = False

    def stop(self):
        if self.process.poll() is not None:
            raise Inconclusive("child completed before event-triggered SIGSTOP")
        try:
            os.kill(self.process.pid, signal.SIGSTOP)
        except ProcessLookupError as exc:
            raise Inconclusive("child exited before SIGSTOP delivery") from exc
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            pid, status = os.waitpid(self.process.pid, os.WUNTRACED | os.WNOHANG)
            if pid:
                if os.WIFSTOPPED(status):
                    self.stopped = True
                    return
                self.process.returncode = os.waitstatus_to_exitcode(status)
                raise Inconclusive("child exited while establishing stop barrier")
            # A bounded condition poll; the stop event, never elapsed time, is
            # the barrier that authorizes the next experiment operation.
            select.select([], [], [], 0.001)
        raise Inconclusive("could not establish stopped child barrier")

    def resume(self):
        if self.stopped:
            try:
                os.kill(self.process.pid, signal.SIGCONT)
            except ProcessLookupError:
                pass
            self.stopped = False

    def wait(self):
        try:
            return self.process.wait(timeout=self.timeout)
        except subprocess.TimeoutExpired as exc:
            raise Inconclusive("child exceeded bounded wait: " + " ".join(self.argv)) from exc

    def text(self):
        return self.stdout_path.read_text(errors="replace") + self.stderr_path.read_text(errors="replace")

    def close(self):
        if self.process.poll() is None:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.process.wait(timeout=5)
        self.stdout.close()
        self.stderr.close()


class Watch:
    """inotify identifies actual path creation/modification, not guessed delays."""
    def __init__(self, directory):
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.fd = self.libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1")
        # CREATE, MOVED_TO, MODIFY, CLOSE_WRITE, DELETE.
        if self.libc.inotify_add_watch(self.fd, os.fsencode(directory), 0x38A) < 0:
            self.close()
            raise OSError(ctypes.get_errno(), "inotify_add_watch")

    def events(self, timeout=0):
        if not select.select([self.fd], [], [], timeout)[0]:
            return []
        data = os.read(self.fd, 65536)
        result, offset = [], 0
        while offset + 16 <= len(data):
            _, mask, _, length = struct.unpack_from("iIII", data, offset)
            name = os.fsdecode(data[offset + 16:offset + 16 + length].split(b"\0", 1)[0])
            result.append((name, mask))
            offset += 16 + length
        return result

    def stop_on(self, child, target, predicate, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for name, _ in self.events(min(0.1, max(0, deadline - time.monotonic()))):
                try:
                    matched = name == target.name and predicate()
                except FileNotFoundError:
                    matched = False
                if matched:
                    child.stop()
                    try:
                        still_matched = predicate()
                    except FileNotFoundError:
                        still_matched = False
                    if not still_matched:
                        raise Inconclusive("filesystem condition disappeared before confirmed stop")
                    return True
            if child.process.poll() is not None:
                return False
        raise Inconclusive("filesystem barrier was not reached: " + str(target))

    def close(self):
        os.close(self.fd)


class MCP:
    def __init__(self, binary, database, directory, timeout):
        self.log = (directory / "mcp.stderr").open("wb")
        self.process = subprocess.Popen([str(binary), "serve", str(database)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
            start_new_session=True, env=child_environment())
        self.buffer, self.sequence, self.transcript = b"", 0, []
        self.timeout, self.directory = timeout, directory
        try:
            self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "swan-concurrency-check", "version": "1"}})
        except BaseException:
            self.close()
            raise

    def request(self, method, params):
        self.sequence += 1
        message = {"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params}
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + self.timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise Inconclusive("MCP response timed out")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise EOFError("MCP server closed its output")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        result = json.loads(line)
        self.transcript.append({"request": message, "response": result})
        require(result.get("id") == self.sequence, "MCP response ID mismatch")
        return result

    def probe(self):
        answer = self.request("tools/call", {"name": "find_symbol", "arguments": {
            "name_path_pattern": "probe", "include_body": False}})
        if "error" in answer or answer.get("result", {}).get("isError"):
            require(any(word in json.dumps(answer).lower() for word in ("locked", "busy", "in progress", "another writer")),
                    "query error lacked an explicit contention diagnostic: " + repr(answer))
            return {"refused": answer}
        rows = json.loads(answer["result"]["content"][0]["text"])
        require(len(rows) == 1, "successful query returned missing/duplicate probe: " + repr(rows))
        return rows[0]["relative_path"]

    def close(self):
        (self.directory / "mcp-transcript.json").write_text(json.dumps(self.transcript, indent=2) + "\n")
        if self.process.poll() is None:
            try:
                self.process.stdin.close()
            except BrokenPipeError:
                pass
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(self.process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self.process.wait(timeout=5)
        self.log.close()


def connect(database):
    # No accidental database creation; timeout zero makes lock outcomes visible.
    return sqlite3.connect(database.as_uri() + "?mode=rw", uri=True, timeout=0)


def active_journal(path):
    try:
        return path.stat().st_size > 512
    except FileNotFoundError:
        return False


def recoverable_journal(path):
    try:
        with path.open("rb") as stream:
            # The valid rollback journal magic is written before database pages
            # may be overwritten; an unflushed zero header cannot prove recovery.
            return path.stat().st_size > 512 and stream.read(8) == bytes.fromhex("d9d505f920a163d7")
    except FileNotFoundError:
        return False


def snapshot(database):
    with closing(connect(database)) as connection:
        connection.execute("BEGIN")
        integrity = connection.execute("PRAGMA integrity_check").fetchall()
        require(integrity == [("ok",)], "integrity_check failed: " + repr(integrity))
        hasher, counts = hashlib.sha256(), {}
        queries = {
            "symbols": "SELECT scip,name,name_path,kind,signature,def_file,def_line,def_col,body_start,body_end,in_repo FROM symbols ORDER BY scip",
            "occurrences": "SELECT s.scip,o.file,o.start_line,o.start_col,o.end_line,o.end_col,o.is_def,e.scip FROM occurrences o JOIN symbols s ON s.id=o.symbol_id LEFT JOIN symbols e ON e.id=o.enclosing_id ORDER BY 1,2,3,4",
            "relationships": "SELECT s.scip,t.scip,r.file,r.is_impl,r.is_ref,r.is_typedef,r.is_def FROM relationships r JOIN symbols s ON s.id=r.symbol_id JOIN symbols t ON t.id=r.related_id ORDER BY 1,2,3",
            "files": "SELECT file,hash,rows FROM files ORDER BY file",
        }
        for name, sql in queries.items():
            count = 0
            for row in connection.execute(sql):
                hasher.update(json.dumps([name, row], separators=(",", ":")).encode())
                count += 1
            counts[name] = count
        connection.rollback()
        return {"digest": hasher.hexdigest(), "counts": counts}


def fixture(directory, generation, count):
    rows = directory / ("rows-" + generation)
    rows.mkdir()
    filename = generation + ".ts"
    with (rows / "symbols.tsv").open("w") as symbols, \
         (rows / "extents.tsv").open("w") as extents, \
         (rows / "occurrences.tsv").open("w") as occurrences:
        for index in range(count):
            name = "probe" if index == 0 else "item" + str(index)
            scip = "scip-typescript npm concurrency-fixture 0.0.0 " + name + "()."
            symbols.write(f"{scip}\t{name}\t17\t\tfunction {name}(): void // {generation}\n")
            extents.write(f"{scip}\t{filename}\t{index}\t0\t{index}\t20\n")
            occurrences.write(f"{scip}\t{filename}\t{index}\t9\t{index}\t{9 + len(name)}\tdef\n")
    (rows / "relationships.tsv").write_text("")
    return rows


class Experiment:
    def __init__(self, options):
        self.options, self.binary = options, options.binary.resolve(strict=True)
        options.output_parent.mkdir(parents=True, exist_ok=True)
        self.directory = Path(tempfile.mkdtemp(prefix="swan-concurrency-", dir=options.output_parent)).resolve()
        self.repository = self.directory / "repo"
        self.repository.mkdir()
        self.children, self.results, self.expected = [], [], {}
        self.rows = {g: fixture(self.directory, g, options.rows) for g in "ABC"}
        for generation in "ABC":
            (self.repository / (generation + ".ts")).write_text("export function probe() {}\n")
        self.baseline = self.directory / "baseline.db"

    def spawn(self, command, rows, db, directory, label):
        child = Child([self.binary, command, rows, db, self.repository], directory, label, self.options.timeout)
        self.children.append(child)
        return child

    def build(self, generation, db, directory, command="index", label=None):
        child = self.spawn(command, self.rows[generation], db, directory, label or command + generation)
        require(child.wait() == 0, "baseline/retry failed: " + child.text())
        return child

    def case(self, name):
        directory = self.directory / name
        directory.mkdir()
        database = directory / "swan.db"
        shutil.copy2(self.baseline, database)
        return directory, database

    def equals(self, database, generation):
        actual = snapshot(database)
        require(actual == self.expected[generation], f"map is not complete generation {generation}: {actual}")
        return actual

    def explicit_refusal(self, child):
        require(child.process.returncode is not None and child.process.returncode != 0,
                "writer unexpectedly reported success while conflicting writer was paused")
        require(any(word in child.text().lower() for word in ("locked", "busy", "in progress", "another writer")),
                "nonzero writer lacked explicit contention diagnostic: " + child.text())

    def prepare(self):
        for generation in "ABC":
            path = self.baseline if generation == "A" else self.directory / ("expected-" + generation + ".db")
            self.build(generation, path, self.directory)
            self.expected[generation] = snapshot(path)
        with closing(connect(self.baseline)) as connection:
            self.pragmas = {name: connection.execute("PRAGMA " + name).fetchone()[0]
                            for name in ("journal_mode", "synchronous", "locking_mode")}
        require(self.pragmas["journal_mode"] in ("delete", "truncate", "persist"),
                "harness requires rollback journal mode; observed " + repr(self.pragmas))

    def locked_refresh(self, lock):
        directory, database = self.case("held-" + lock)
        holder = connect(database)
        try:
            holder.execute("BEGIN" if lock == "reader" else "BEGIN IMMEDIATE")
            holder.execute("SELECT count(*) FROM symbols").fetchone()
            if lock == "writer":
                holder.execute("UPDATE meta SET value=value WHERE key='schema_version'")
            child = self.spawn("refresh", self.rows["B"], database, directory, "contended")
            child.wait()
            self.explicit_refusal(child)
        finally:
            holder.rollback()
            holder.close()
        self.equals(database, "A")
        self.build("B", database, directory, "refresh", "retry")
        self.equals(database, "B")
        return "explicit refusal preserved A; retry after releasing SQLite lock produced B"

    def refresh_snapshots(self):
        directory, database = self.case("refresh-snapshots")
        client = MCP(self.binary, database, directory, self.options.timeout)
        watcher = Watch(directory)
        observations = []
        child = None
        try:
            require(client.probe() == "A.ts", "persistent reader did not open generation A")
            child = self.spawn("refresh", self.rows["B"], database, directory, "refresh")
            journal = Path(str(database) + "-journal")
            if not watcher.stop_on(child, journal, lambda: active_journal(journal),
                                   self.options.timeout):
                raise Inconclusive("refresh finished before journal barrier")
            # Child is stopped inside its uncommitted transaction. The old map
            # remains the only valid visible generation (or explicit SQLITE_BUSY
            # if the writer already spilled pages and holds an exclusive lock).
            try:
                self.equals(database, "A")
                observations.append("SQLite reader observed complete A during uncommitted B")
            except sqlite3.OperationalError as exc:
                require("locked" in str(exc), "unexpected snapshot failure: " + str(exc))
                observations.append("SQLite reader explicitly busy during uncommitted B")
            child.resume()
            deadline = time.monotonic() + self.options.timeout
            while child.process.poll() is None and time.monotonic() < deadline:
                try:
                    probe = client.probe()
                except EOFError:
                    status = client.process.wait(timeout=self.options.timeout)
                    diagnostic = (client.directory / "mcp.stderr").read_text(errors="replace")
                    require(status != 0 and any(word in diagnostic.lower() for word in ("busy", "locked")),
                            "reader exited without explicit contention diagnostic")
                    observations.append("reader process failed closed on contention; restart needed")
                    break
                require(isinstance(probe, dict) or probe in ("A.ts", "B.ts"), "mixed or unknown query generation")
                observations.append(probe)
                if len(observations) > 200:
                    break
            child.wait()
            if child.process.returncode != 0:
                self.explicit_refusal(child)
                self.equals(database, "A")
                self.build("B", database, directory, "refresh", "retry")
                observations.append("refresh explicitly refused contention; uncontended retry passed")
            self.equals(database, "B")
            if client.process.poll() is not None:
                client.close()
                restarted = directory / "restarted-reader"
                restarted.mkdir()
                client = MCP(self.binary, database, restarted, self.options.timeout)
            require(client.probe() == "B.ts", "persistent reader did not see committed in-place refresh")
            return observations
        finally:
            if child is not None:
                child.resume()
            watcher.close()
            client.close()

    def blocked_query(self):
        directory, database = self.case("blocked-query")
        client = MCP(self.binary, database, directory, self.options.timeout)
        holder = connect(database)
        try:
            require(client.probe() == "A.ts", "query warmup failed")
            holder.execute("BEGIN EXCLUSIVE")
            try:
                result = client.probe()
                require(isinstance(result, dict) and "refused" in result,
                        "successful query bypassed held exclusive SQLite lock")
                return "MCP explicitly refused blocked query"
            except EOFError:
                status = client.process.wait(timeout=self.options.timeout)
                diagnostic = (directory / "mcp.stderr").read_text(errors="replace")
                require(status != 0 and any(word in diagnostic.lower() for word in ("busy", "locked")),
                        "MCP exited without explicit lock diagnostic")
                return "MCP process failed closed on SQLite contention; connection recovery requires restart"
        finally:
            holder.rollback()
            holder.close()
            client.close()
            self.equals(database, "A")

    def simultaneous_refresh(self):
        directory, database = self.case("simultaneous-refresh")
        watcher = Watch(directory)
        first = self.spawn("refresh", self.rows["B"], database, directory, "B")
        try:
            journal = Path(str(database) + "-journal")
            if not watcher.stop_on(first, journal, lambda: active_journal(journal),
                                   self.options.timeout):
                raise Inconclusive("first refresh completed before transaction barrier")
            second = self.spawn("refresh", self.rows["C"], database, directory, "C")
            second.wait()
            self.explicit_refusal(second)
            first.resume()
            require(first.wait() == 0, "first refresh failed: " + first.text())
            self.equals(database, "B")
            self.build("C", database, directory, "refresh", "retry-C")
            self.equals(database, "C")
            return "C refused during paused B; complete B committed; retry produced complete C"
        finally:
            first.resume()
            watcher.close()

    def interrupted_refresh(self):
        directory, database = self.case("interrupted-refresh")
        watcher = Watch(directory)
        child = self.spawn("refresh", self.rows["B"], database, directory, "killed-B")
        try:
            journal = Path(str(database) + "-journal")
            if not watcher.stop_on(child, database, lambda: recoverable_journal(journal),
                                   self.options.timeout):
                raise Inconclusive("refresh completed before a database-write/recovery-journal barrier")
            baseline_hash = hashlib.sha256(self.baseline.read_bytes()).hexdigest()
            interrupted_hash = hashlib.sha256(database.read_bytes()).hexdigest()
            if interrupted_hash == baseline_hash:
                raise Inconclusive("main database did not change before interruption; rollback recovery not exercised")
            with journal.open("rb") as stream:
                journal_header = stream.read(28).hex()
            (directory / "interruption.json").write_text(json.dumps({
                "observed_event": "main database modified with valid rollback journal; child stopped and condition rechecked",
                "baseline_sha256": baseline_hash, "interrupted_sha256": interrupted_hash,
                "journal_header_hex": journal_header, "journal_size": journal.stat().st_size,
                "child_pid": child.process.pid, "planned_signal": "SIGKILL",
            }, indent=2) + "\n")
            os.killpg(child.process.pid, signal.SIGKILL)
            require(child.wait() == -signal.SIGKILL, "unexpected killed process status")
            child.stopped = False
            self.equals(database, "A")  # SQLite performs recovery, if needed.
            self.build("B", database, directory, "refresh", "retry")
            self.equals(database, "B")
            return "SIGKILL during observed journal transaction recovered A; retry produced B (not a power-loss test)"
        finally:
            child.resume()
            watcher.close()

    def temp_collision(self):
        directory, database = self.case("full-index-temp-collision")
        watcher = Watch(directory)
        temp = Path(str(database) + ".tmp")
        first, second = None, None
        try:
            first = self.spawn("index", self.rows["B"], database, directory, "B")
            if not watcher.stop_on(first, temp, temp.exists, self.options.timeout):
                raise Inconclusive("first index completed without an observed .tmp barrier; implementation may use unique temp names")
            original_inode = temp.stat().st_ino
            watcher.events()  # Drain only old events after the established stop.
            second = self.spawn("index", self.rows["C"], database, directory, "C")
            collided = watcher.stop_on(second, temp,
                lambda: temp.exists() and temp.stat().st_ino != original_inode, self.options.timeout)
            if not collided:
                self.explicit_refusal(second)
                require(temp.exists() and temp.stat().st_ino == original_inode,
                        "refused writer altered first writer's temporary database")
                self.equals(database, "A")
                first.resume()
                require(first.wait() == 0, "first full index failed after other writer refusal")
                self.equals(database, "B")
                return "second writer refused before replacing first writer's .tmp; A preserved until complete B"
            # Both writers are stopped. C has replaced B's path. B still owns
            # its unlinked SQLite inode. Resume B alone, keeping C suspended.
            collision = {"B_temp_inode": original_inode, "C_temp_inode": temp.stat().st_ino}
            first.resume()
            first.wait()
            collision.update({"B_exit": first.process.returncode, "B_output": first.text()})
            try:
                collision["published_snapshot_while_C_stopped"] = snapshot(database)
            except Exception as exc:
                collision["published_snapshot_error"] = type(exc).__name__ + ": " + str(exc)
            (directory / "collision.json").write_text(json.dumps(collision, indent=2) + "\n")
            raise AssertionError("concurrent full writers replaced the same .tmp path; see collision.json for publication outcome")
        finally:
            # Terminate C while still paused if a collision occurred. Resuming
            # it could write through an inode B already published; no need to
            # extend the fault beyond the evidence already captured.
            if second is not None and second.stopped:
                second.close()
                second.stopped = False
            if first is not None:
                first.resume()
            watcher.close()

    def persistent_replace(self):
        directory, database = self.case("persistent-full-replace")
        client = MCP(self.binary, database, directory, self.options.timeout)
        try:
            require(client.probe() == "A.ts", "persistent reader warmup failed")
            self.build("B", database, directory)
            self.equals(database, "B")
            result = client.probe()
            require(result == "B.ts", "fresh SQLite connection sees B but persistent MCP reader returned " + repr(result))
            return "persistent MCP reader observes B after full pathname replacement"
        finally:
            client.close()

    def writer_entry_locks(self):
        directory, database = self.case("writer-entry-locks")
        alias = directory / "alias"
        alias.symlink_to(directory, target_is_directory=True)
        marker = directory / "scip-started"
        marker.write_text("held writer owns intermediate output\n")
        source = directory / "kotlin-repo"
        source.mkdir()
        (source / "Example.kt").write_text("fun example() = 1\n")
        lock_path = Path(str(database) + ".lock")
        with lock_path.open("a+b") as holder:
            fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
            inode = lock_path.stat().st_ino
            commands = [
                ("direct-index", [self.binary, "index", self.rows["B"], database, self.repository]),
                ("alias-refresh", [self.binary, "refresh", self.rows["B"], alias / "swan.db", self.repository]),
                ("pipeline", [self.binary, "map", source, directory]),
                ("alias-pipeline", [self.binary, "map", source, alias]),
            ]
            for name, argv in commands:
                child = Child(argv, directory, name, self.options.timeout)
                self.children.append(child)
                child.wait()
                self.explicit_refusal(child)
                self.equals(database, "A")
                require(marker.read_text() == "held writer owns intermediate output\n",
                        "refused pipeline changed intermediate output")
                require(lock_path.stat().st_ino == inode, "writer replaced an active lock file")
            independent = directory / "independent"
            independent.mkdir()
            independent_db = independent / "swan.db"
            self.build("B", independent_db, independent)
            self.equals(independent_db, "B")
            fcntl.flock(holder, fcntl.LOCK_UN)
        # Verify both normal release and release after an index abort. The
        # invalid input is deliberately inside this disposable directory.
        self.build("B", database, directory, "refresh", "after-release")
        self.equals(database, "B")
        invalid = self.spawn("index", directory / "missing-rows", database, directory, "invalid-input")
        require(invalid.wait() != 0, "missing rows unexpectedly produced a successful map")
        require("cannot read" in invalid.text().lower(), "invalid-input case failed before acquiring its writer lock")
        self.equals(database, "B")
        self.build("C", database, directory, "refresh", "after-abort")
        self.equals(database, "C")
        # A successful unsupported-language pipeline calls the inner index
        # implementation under its already-held lock. No indexer is needed.
        inner_output = directory / "nested-pipeline"
        child = Child([self.binary, "map", source, inner_output], directory, "nested-pipeline", self.options.timeout)
        self.children.append(child)
        require(child.wait() == 0, "pipeline's inner index could not use its held writer lock: " + child.text())
        empty = snapshot(inner_output / "swan.db")
        require(empty["counts"]["symbols"] == 0, "expected empty structural-only Kotlin map")
        require(lock_path.stat().st_ino == inode, "lock file was unlinked during release")
        return "map/index/refresh and parent aliases share ownership; independent target proceeds; normal/abort release and nested pipeline pass"

    def run(self):
        print("Artifacts: " + str(self.directory), flush=True)
        try:
            self.prepare()
            cases = [
                ("held-reader", lambda: self.locked_refresh("reader")),
                ("held-writer", lambda: self.locked_refresh("writer")),
                ("refresh-snapshots", self.refresh_snapshots),
                ("blocked-query", self.blocked_query),
                ("simultaneous-refresh", self.simultaneous_refresh),
                ("interrupted-refresh", self.interrupted_refresh),
                ("temp-collision", self.temp_collision),
                ("persistent-replace", self.persistent_replace),
                ("writer-entry-locks", self.writer_entry_locks),
            ]
            for name, operation in cases:
                if self.options.case and name not in self.options.case:
                    continue
                try:
                    detail, status = operation(), "PASS"
                except Inconclusive as exc:
                    detail, status = str(exc), "INCONCLUSIVE"
                except Exception as exc:
                    detail, status = type(exc).__name__ + ": " + str(exc), "FAIL"
                finally:
                    for child in self.children:
                        child.close()
                    self.children.clear()
                self.results.append({"case": name, "status": status, "detail": detail})
                print(status + " " + name + ": " + json.dumps(detail), flush=True)
                self.save()
        finally:
            for child in self.children:
                child.close()
            self.save()
        return 1 if any(r["status"] == "FAIL" for r in self.results) else (2 if any(r["status"] == "INCONCLUSIVE" for r in self.results) else 0)

    def save(self):
        (self.directory / "results.json").write_text(json.dumps({
            "binary": str(self.binary), "sha256": hashlib.sha256(self.binary.read_bytes()).hexdigest(),
            "python_sqlite_version": sqlite3.sqlite_version,
            "note": "Python SQLite is a separate lock/snapshot oracle; Swan uses its pinned embedded SQLite",
            "rows_per_generation": self.options.rows, "timeout_seconds": self.options.timeout,
            "reopened_baseline_pragmas": getattr(self, "pragmas", None),
            "input_provenance": "hand-authored synthetic flattened SCIP rows; no indexer executed",
            "expected_snapshots": self.expected, "results": self.results,
            "scope": "local Linux filesystem and separate processes only; no production/trust/config changes",
        }, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--output-parent", required=True, type=Path)
    parser.add_argument("--rows", type=int, default=50000)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--case", action="append", choices=["held-reader", "held-writer", "refresh-snapshots",
        "blocked-query", "simultaneous-refresh", "interrupted-refresh", "temp-collision", "persistent-replace",
        "writer-entry-locks"])
    options = parser.parse_args()
    if not sys.platform.startswith("linux"):
        parser.error("this event-controlled harness qualifies Linux only")
    if not 1000 <= options.rows <= 250000 or not 5 <= options.timeout <= 60:
        parser.error("require 1000 <= rows <= 250000 and 5 <= timeout <= 60")
    if not options.binary.is_file() or not os.access(options.binary, os.X_OK):
        parser.error("--binary must identify an existing executable")
    return Experiment(options).run()


if __name__ == "__main__":
    raise SystemExit(main())

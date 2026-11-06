"""Exercise Swan's native writer ownership on real disposable POSIX files.

Only the Goose builder ABI is stubbed; the production native C helper and OS
locks run unchanged. No Swan installation, repository trust or map is touched.
"""

import ctypes
import os
from pathlib import Path
import select
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


class Slice(ctypes.Structure):
    """Represent the Goose byte-slice ABI passed to native helpers."""
    _fields_ = [("data", ctypes.c_void_p), ("length", ctypes.c_int64)]


class Builder(ctypes.Structure):
    """Represent the bounded test builder that receives native error messages."""
    _fields_ = [("text", ctypes.c_char * 16384), ("length", ctypes.c_size_t)]


def load_native(path):
    """Load the compiled native library and declare its writer-lock ctypes signatures."""
    library = ctypes.CDLL(str(path))
    library.swan_writer_lock.argtypes = [Slice, ctypes.POINTER(Builder)]
    library.swan_writer_lock.restype = ctypes.c_int64
    library.swan_writer_unlock.argtypes = [ctypes.c_int64]
    library.swan_writer_complete.argtypes = [ctypes.c_int64]
    return library


def acquire(library, path):
    """Try native writer ownership for a path and return its handle and diagnostic."""
    buffer = ctypes.create_string_buffer(os.fsencode(path))
    error = Builder()
    handle = library.swan_writer_lock(Slice(ctypes.addressof(buffer), len(buffer.value)), ctypes.byref(error))
    return handle, bytes(error.text).decode()


@unittest.skipUnless(sys.platform.startswith("linux"), "native source currently qualifies Linux only")
class WriterLockTests(unittest.TestCase):
    """Qualify native writer ownership using isolated files and actual OS subprocesses."""
    @classmethod
    def setUpClass(cls):
        """Compile production native helpers with a minimal Goose builder shim."""
        compiler = shutil.which("cc")
        if not compiler:
            raise unittest.SkipTest("C compiler required for native lock qualification")
        cls.build = tempfile.TemporaryDirectory(prefix="swan-native-lock-build-")
        root = Path(cls.build.name)
        (root / "goose.h").write_text("""
#include <stddef.h>
#include <stdint.h>
typedef struct { char text[16384]; size_t length; } test_builder;
typedef test_builder *gs_rref;
void gs_bld_append(gs_rref out, const void *data, size_t length);
""")
        (root / "builder.c").write_text("""
#include "goose.h"
#include <string.h>
void gs_bld_append(gs_rref out, const void *data, size_t length) {
    if (length > sizeof(out->text) - out->length - 1)
        length = sizeof(out->text) - out->length - 1;
    memcpy(out->text + out->length, data, length);
    out->length += length;
    out->text[out->length] = 0;
}
""")
        cls.library_path = root / "swan-native.so"
        native = Path(__file__).resolve().parents[1] / "native/swan_sys.c"
        subprocess.run([compiler, "-shared", "-fPIC", "-std=c11", "-Wall", "-Wextra", "-Werror",
                        "-I", str(root), str(native), str(root / "builder.c"),
                        "-o", str(cls.library_path)], check=True, timeout=30)
        cls.library = load_native(cls.library_path)

    @classmethod
    def tearDownClass(cls):
        """Remove the temporary native-library build directory."""
        cls.build.cleanup()

    def setUp(self):
        """Create an isolated case directory and track acquired lock handles."""
        self.scratch = tempfile.TemporaryDirectory(prefix="swan-native-lock-case-")
        self.directory = Path(self.scratch.name)
        self.handles = []

    def tearDown(self):
        """Release tracked ownership handles and remove the case directory."""
        for handle in self.handles:
            self.library.swan_writer_unlock(handle)
        self.scratch.cleanup()

    def own(self, path):
        """Require successful ownership and register its handle for cleanup."""
        handle, error = acquire(self.library, path)
        self.assertGreater(handle, 0, error)
        self.handles.append(handle)
        return handle

    def refuse(self, path):
        """Require competing ownership to fail with an explicit writer diagnostic."""
        handle, error = acquire(self.library, path)
        self.assertEqual(handle, 0)
        self.assertIn("another writer is in progress", error)

    def test_same_map_refused_and_stable_lock_file_reused(self):
        """Verify exclusion and reuse of the same lock inode after normal release."""
        database = self.directory / "swan.db"
        first = self.own(database)
        lock_file = Path(str(database) + ".lock")
        inode = lock_file.stat().st_ino
        self.refuse(database)
        self.library.swan_writer_unlock(first)
        self.handles.remove(first)
        self.own(database)
        self.assertEqual(lock_file.stat().st_ino, inode)

    def test_parent_aliases_cover_database_not_created_yet(self):
        """Verify parent-directory aliases share ownership before the database exists."""
        directory = self.directory / "real"
        directory.mkdir()
        alias = self.directory / "alias"
        alias.symlink_to(directory, target_is_directory=True)
        self.own(directory / "swan.db")
        self.refuse(alias / "swan.db")
        self.refuse(directory / ".." / "real" / "swan.db")

    def test_database_file_symlink_refused_before_mutation(self):
        """Verify a database-file symlink is refused without changing files or creating locks."""
        database = self.directory / "swan.db"
        database.write_bytes(b"disposable path identity fixture")
        alias = self.directory / "alias.db"
        alias.symlink_to(database)
        handle, error = acquire(self.library, alias)
        self.assertEqual(handle, 0)
        self.assertIn("database symlinks are not supported", error)
        self.assertTrue(alias.is_symlink())
        self.assertEqual(database.read_bytes(), b"disposable path identity fixture")
        self.assertFalse(Path(str(database) + ".lock").exists())
        self.assertFalse(Path(str(alias) + ".lock").exists())

    def test_lock_file_symlinks_refused_without_touching_targets(self):
        """Refuse existing and dangling lock symlinks without locking their targets."""
        for existing in (True, False):
            with self.subTest(existing=existing):
                database = self.directory / f"map-{existing}.db"
                target = self.directory / f"target-{existing}"
                contents = b"unrelated file"
                if existing:
                    target.write_bytes(contents)
                lock_file = Path(str(database) + ".lock")
                lock_file.symlink_to(target)
                handle, error = acquire(self.library, database)
                if handle:
                    self.handles.append(handle)
                self.assertEqual(handle, 0, "writer followed a lock-file symlink")
                self.assertIn("cannot open map writer lock", error)
                self.assertTrue(lock_file.is_symlink())
                self.assertFalse(database.exists())
                if existing:
                    self.assertEqual(target.read_bytes(), contents)
                    import fcntl
                    with target.open("rb") as stream:
                        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                else:
                    self.assertFalse(target.exists())

    def test_database_deletion_does_not_change_lock_identity(self):
        """Verify deleting and recreating the database cannot bypass existing ownership."""
        database = self.directory / "swan.db"
        database.write_bytes(b"before schema replacement")
        self.own(database)
        database.unlink()
        self.refuse(database)
        database.write_bytes(b"after schema replacement")
        self.refuse(database)

    def test_independent_maps_can_have_independent_writers(self):
        """Verify separate target maps permit simultaneous independent ownership."""
        self.own(self.directory / "first.db")
        self.own(self.directory / "second.db")

    def test_process_death_releases_ownership(self):
        """Verify ownership is released when its sole holding process is killed."""
        database = self.directory / "swan.db"
        program = """
import signal, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from test_writer_lock import acquire, load_native
handle, error = acquire(load_native(sys.argv[2]), Path(sys.argv[3]))
if not handle:
    raise RuntimeError(error)
print('OWNED', flush=True)
signal.pause()
"""
        child = subprocess.Popen([sys.executable, "-c", program, str(Path(__file__).resolve().parent),
                                  str(self.library_path), str(database)], stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE)
        try:
            self.assertTrue(select.select([child.stdout], [], [], 5)[0], "child failed to acquire lock")
            self.assertEqual(child.stdout.readline(), b"OWNED\n")
            self.refuse(database)
            child.kill()
            child.wait(timeout=5)
            self.own(database)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=5)
            child.stdout.close()
            child.stderr.close()

    def orphan_writer(self, operation):
        """Verify an exec'd child retains ownership after parent death until its final write and exit."""
        database = self.directory / "swan.db"
        ready, gate = self.directory / "ready.fifo", self.directory / "gate.fifo"
        output = self.directory / "indexer-output"
        os.mkfifo(ready)
        os.mkfifo(gate)
        ready_fd = os.open(ready, os.O_RDONLY | os.O_NONBLOCK)
        program = r'''
import ctypes, os, signal, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from test_writer_lock import Slice, Builder, acquire, load_native
library = load_native(sys.argv[2])
handle, error = acquire(library, Path(sys.argv[3]))
if not handle:
    raise RuntimeError(error)
child_code = """
import os, sys
from pathlib import Path
ready = os.open(sys.argv[1], os.O_WRONLY)
os.write(ready, (str(os.getpid()) + '\\n').encode())
os.close(ready)
gate = os.open(sys.argv[2], os.O_RDONLY)
os.read(gate, 1)
os.close(gate)
Path(sys.argv[3]).write_text('child wrote after parent death')
"""
arguments = [sys.executable, '-c', child_code, sys.argv[4], sys.argv[5], sys.argv[6]]
buffers = []
def sliced(value):
    buffer = ctypes.create_string_buffer(value)
    buffers.append(buffer)
    return Slice(ctypes.addressof(buffer), len(value))
argv = sliced(b'\0'.join(os.fsencode(arg) for arg in arguments) + b'\0')
empty = sliced(b'')
if sys.argv[7] == 'spawn':
    library.swan_spawn.argtypes = [Slice, Slice, Slice, Slice]
    library.swan_spawn.restype = ctypes.c_int64
    pid = library.swan_spawn(argv, empty, empty, sliced(os.fsencode(sys.argv[6] + '.log')))
    if pid <= 0:
        raise RuntimeError('native spawn failed')
    signal.pause()
else:
    library.swan_run.argtypes = [Slice, Slice, Slice, ctypes.c_int64, ctypes.POINTER(Builder), ctypes.POINTER(Builder)]
    out, err = Builder(), Builder()
    library.swan_run(argv, empty, empty, 20000, ctypes.byref(out), ctypes.byref(err))
'''
        parent = subprocess.Popen([sys.executable, "-c", program, str(Path(__file__).resolve().parent),
                                   str(self.library_path), str(database), str(ready), str(gate),
                                   str(output), operation], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        child_pid, child_finished = None, False
        try:
            self.assertTrue(select.select([ready_fd], [], [], 5)[0], "native child never reached write barrier")
            child_pid = int(os.read(ready_fd, 128).strip())
            parent.kill()
            parent.wait(timeout=5)
            self.refuse(database)  # Child has exec'd and still owns the writer fd.
            gate_fd = os.open(gate, os.O_WRONLY | os.O_NONBLOCK)
            os.write(gate_fd, b"x")
            os.close(gate_fd)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                handle, error = acquire(self.library, database)
                if handle:
                    self.handles.append(handle)
                    child_finished = True
                    break
                self.assertIn("another writer is in progress", error)
                select.select([], [], [], 0.001)  # Wait for observed lock release.
            self.assertTrue(child_finished, "child exit did not release inherited writer ownership")
            self.assertEqual(output.read_text(), "child wrote after parent death")
        finally:
            os.close(ready_fd)
            if parent.poll() is None:
                parent.kill()
                parent.wait(timeout=5)
            if child_pid and not child_finished:
                try:
                    os.kill(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            parent.stderr.close()

    def test_spawn_indexer_keeps_lock_after_parent_death(self):
        """Exercise inherited ownership through the production indexer-spawn helper."""
        self.orphan_writer("spawn")

    def test_run_flattener_keeps_lock_after_parent_death(self):
        """Exercise inherited ownership through the production synchronous-run helper."""
        self.orphan_writer("run")

    def service_writer(self, operation, outcome="success"):
        """Check release or retained ownership while an inherited-FD service survives its client."""
        directory = Path(tempfile.mkdtemp(prefix="service-", dir=self.directory))
        database = directory / "swan.db"
        ready, gate = directory / "ready.fifo", directory / "gate.fifo"
        output = directory / "service-output"
        os.mkfifo(ready)
        os.mkfifo(gate)
        ready_fd = os.open(ready, os.O_RDONLY | os.O_NONBLOCK)
        first = self.own(database)
        # The service finishes this job's output before the foreground client
        # exits, then stays idle. Successful completion is a cooperating tool
        # contract, not isolation from a descendant that keeps writing anyway.
        program = r'''
import os, signal, sys
from pathlib import Path
completed, signal_done = os.pipe()
pid = os.fork()
if pid == 0:
    os.close(completed)
    if sys.argv[4] == 'timeout':
        os.setsid()  # A daemon can outlive swan_run's process-group timeout kill.
    null = os.open('/dev/null', os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(null, fd)
    os.close(null)
    if sys.argv[4] == 'success':
        Path(sys.argv[3]).write_text('persistent service finished this job')
    ready = os.open(sys.argv[1], os.O_WRONLY)
    os.write(ready, (str(os.getpid()) + '\n').encode())
    os.close(ready)
    os.write(signal_done, b'd')
    os.close(signal_done)
    gate = os.open(sys.argv[2], os.O_RDONLY)
    os.read(gate, 1)
    os.close(gate)
    if sys.argv[4] != 'success':
        Path(sys.argv[3]).write_text('service wrote after client failure')
    os._exit(0)
os.close(signal_done)
assert os.read(completed, 1) == b'd'
os.close(completed)
if sys.argv[4] == 'timeout':
    signal.pause()
sys.exit(1 if sys.argv[4] == 'failure' else 0)
'''
        arguments = [sys.executable, "-c", program, str(ready), str(gate), str(output), outcome]
        buffers = []

        def sliced(value):
            """Keep each ctypes buffer alive for the duration of the native call."""
            buffer = ctypes.create_string_buffer(value)
            buffers.append(buffer)
            return Slice(ctypes.addressof(buffer), len(value))

        argv = sliced(b"\0".join(os.fsencode(arg) for arg in arguments) + b"\0")
        empty = sliced(b"")
        child_pid = None
        child_finished = False
        expected = {"success": 0, "failure": 1, "timeout": -2}[outcome]
        try:
            if operation == "spawn":
                self.library.swan_spawn.argtypes = [Slice, Slice, Slice, Slice]
                self.library.swan_spawn.restype = ctypes.c_int64
                pid = self.library.swan_spawn(argv, empty, empty, sliced(os.fsencode(output) + b".log"))
                self.assertGreater(pid, 0)
                self.library.swan_wait_any.argtypes = [ctypes.POINTER(ctypes.c_int32)]
                self.library.swan_wait_any.restype = ctypes.c_int64
                code = ctypes.c_int32()
                self.assertEqual(self.library.swan_wait_any(ctypes.byref(code)), pid)
                self.assertEqual(code.value, expected)
            else:
                self.library.swan_run.argtypes = [Slice, Slice, Slice, ctypes.c_int64,
                                                  ctypes.POINTER(Builder), ctypes.POINTER(Builder)]
                self.library.swan_run.restype = ctypes.c_int32
                out, err = Builder(), Builder()
                timeout = 1000 if outcome == "timeout" else 5000
                self.assertEqual(self.library.swan_run(argv, empty, empty, timeout,
                                 ctypes.byref(out), ctypes.byref(err)), expected, bytes(err.text))
            self.assertTrue(select.select([ready_fd], [], [], 5)[0], "service never finished its output")
            child_pid = int(os.read(ready_fd, 128).strip())
            if outcome == "success":
                self.assertEqual(output.read_text(), "persistent service finished this job")
            else:
                self.assertFalse(output.exists(), "failure case must still have a pending write")
            os.kill(child_pid, 0)  # Service is alive after foreground job completion.
            self.refuse(database)
            if outcome == "success":
                self.library.swan_writer_complete(first)
            else:
                self.library.swan_writer_unlock(first)
            self.handles.remove(first)
            if outcome == "success":
                self.own(database)
                os.kill(child_pid, 0)  # Success does not rely on idle service termination.
            else:
                self.refuse(database)  # Failure must not release a surviving writer's copy.
                gate_fd = os.open(gate, os.O_WRONLY | os.O_NONBLOCK)
                os.write(gate_fd, b"x")
                os.close(gate_fd)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    handle, error = acquire(self.library, database)
                    if handle:
                        self.handles.append(handle)
                        child_finished = True
                        break
                    self.assertIn("another writer is in progress", error)
                    select.select([], [], [], 0.001)
                self.assertTrue(child_finished, "finished service did not release inherited ownership")
                self.assertEqual(output.read_text(), "service wrote after client failure")
        finally:
            if child_pid is None:
                try:
                    pending = os.read(ready_fd, 128)
                except BlockingIOError:
                    pending = b""
                if pending.strip():
                    child_pid = int(pending.strip())
            os.close(ready_fd)
            if child_pid and not child_finished:
                try:
                    os.kill(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_spawn_completion_releases_idle_service_lock(self):
        """Release inherited service copies after a successful swan_spawn job."""
        self.service_writer("spawn")

    def test_run_completion_releases_idle_service_lock(self):
        """Release inherited service copies after a successful swan_run job."""
        self.service_writer("run")

    def test_spawn_failure_retains_active_service_lock(self):
        """Keep a writing descendant's ownership after the swan_spawn client fails."""
        self.service_writer("spawn", "failure")

    def test_run_failure_and_timeout_retain_active_service_lock(self):
        """Keep surviving writers protected after failure or an escaped-daemon timeout."""
        for outcome in ("failure", "timeout"):
            with self.subTest(outcome=outcome):
                self.service_writer("run", outcome)


if __name__ == "__main__":
    unittest.main()

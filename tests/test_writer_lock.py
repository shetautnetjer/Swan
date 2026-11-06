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
    _fields_ = [("data", ctypes.c_void_p), ("length", ctypes.c_int64)]


class Builder(ctypes.Structure):
    _fields_ = [("text", ctypes.c_char * 16384), ("length", ctypes.c_size_t)]


def load_native(path):
    library = ctypes.CDLL(str(path))
    library.swan_writer_lock.argtypes = [Slice, ctypes.POINTER(Builder)]
    library.swan_writer_lock.restype = ctypes.c_int64
    library.swan_writer_unlock.argtypes = [ctypes.c_int64]
    library.swan_writer_complete.argtypes = [ctypes.c_int64]
    return library


def acquire(library, path):
    buffer = ctypes.create_string_buffer(os.fsencode(path))
    error = Builder()
    handle = library.swan_writer_lock(Slice(ctypes.addressof(buffer), len(buffer.value)), ctypes.byref(error))
    return handle, bytes(error.text).decode()


@unittest.skipUnless(sys.platform.startswith("linux"), "native source currently qualifies Linux only")
class WriterLockTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
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
        cls.build.cleanup()

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="swan-native-lock-case-")
        self.directory = Path(self.scratch.name)
        self.handles = []

    def tearDown(self):
        for handle in self.handles:
            self.library.swan_writer_unlock(handle)
        self.scratch.cleanup()

    def own(self, path):
        handle, error = acquire(self.library, path)
        self.assertGreater(handle, 0, error)
        self.handles.append(handle)
        return handle

    def refuse(self, path):
        handle, error = acquire(self.library, path)
        self.assertEqual(handle, 0)
        self.assertIn("another writer is in progress", error)

    def test_same_map_refused_and_stable_lock_file_reused(self):
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
        directory = self.directory / "real"
        directory.mkdir()
        alias = self.directory / "alias"
        alias.symlink_to(directory, target_is_directory=True)
        self.own(directory / "swan.db")
        self.refuse(alias / "swan.db")
        self.refuse(directory / ".." / "real" / "swan.db")

    def test_database_file_symlink_refused_before_mutation(self):
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

    def test_database_deletion_does_not_change_lock_identity(self):
        database = self.directory / "swan.db"
        database.write_bytes(b"before schema replacement")
        self.own(database)
        database.unlink()
        self.refuse(database)
        database.write_bytes(b"after schema replacement")
        self.refuse(database)

    def test_independent_maps_can_have_independent_writers(self):
        self.own(self.directory / "first.db")
        self.own(self.directory / "second.db")

    def test_process_death_releases_ownership(self):
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

    def orphan_writer(self, operation, outcome="death"):
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
import os, sys, time
from pathlib import Path
if sys.argv[4] != 'death':
    done_read, done_write = os.pipe()
    if os.fork():
        os.close(done_write)
        if sys.argv[4] == 'success':
            assert os.read(done_read, 1) == b'x'
        os.close(done_read)
        if sys.argv[4] == 'timeout':
            time.sleep(30)
        sys.exit(1 if sys.argv[4] == 'failure' else 0)
    os.close(done_read)
    os.setsid()  # Model a build server that outlives a timed-out process group.
    os.close(1)
    os.close(2)
if sys.argv[4] == 'success':
    Path(sys.argv[3]).write_text('child wrote after parent death')
    os.write(done_write, b'x')
if sys.argv[4] != 'death':
    os.close(done_write)
ready = os.open(sys.argv[1], os.O_WRONLY)
os.write(ready, (str(os.getpid()) + '\\n').encode())
os.close(ready)
gate = os.open(sys.argv[2], os.O_RDONLY)
os.read(gate, 1)
os.close(gate)
if sys.argv[4] != 'success':
    Path(sys.argv[3]).write_text('child wrote after parent death')
"""
arguments = [sys.executable, '-c', child_code, sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[8]]
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
    if sys.argv[8] == 'death':
        signal.pause()
    library.swan_wait_any.argtypes = [ctypes.POINTER(ctypes.c_int32)]
    library.swan_wait_any.restype = ctypes.c_int64
    code = ctypes.c_int32()
    assert library.swan_wait_any(ctypes.byref(code)) == pid
    assert code.value == (1 if sys.argv[8] == 'failure' else 0)
else:
    library.swan_run.argtypes = [Slice, Slice, Slice, ctypes.c_int64, ctypes.POINTER(Builder), ctypes.POINTER(Builder)]
    out, err = Builder(), Builder()
    code = library.swan_run(argv, empty, empty, 300 if sys.argv[8] == 'timeout' else 20000, ctypes.byref(out), ctypes.byref(err))
    assert code == (-2 if sys.argv[8] == 'timeout' else 1 if sys.argv[8] == 'failure' else 0)
if sys.argv[8] == 'success':
    library.swan_writer_complete(handle)
else:
    library.swan_writer_unlock(handle)
'''
        parent = subprocess.Popen([sys.executable, "-c", program, str(Path(__file__).resolve().parent),
                                   str(self.library_path), str(database), str(ready), str(gate),
                                   str(output), operation, outcome], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        child_pid, child_finished = None, False
        try:
            self.assertTrue(select.select([ready_fd], [], [], 5)[0], "native child never reached write barrier")
            child_pid = int(os.read(ready_fd, 128).strip())
            if outcome == "death":
                parent.kill()
            parent.wait(timeout=5)
            if outcome != "death":
                self.assertEqual(parent.returncode, 0, parent.stderr.read().decode())
            if outcome == "success":
                # Descendant is still alive at its barrier, but no output is pending.
                handle = self.own(database)
                self.library.swan_writer_unlock(handle)
                self.handles.remove(handle)
            else:
                self.refuse(database)  # Surviving writer still owns the descriptor.
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
            deadline = time.monotonic() + 5
            while not output.exists() and time.monotonic() < deadline:
                select.select([], [], [], 0.001)
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

    def test_spawn_success_releases_idle_descendant_lock(self):
        self.orphan_writer("spawn", "success")

    def test_run_success_releases_idle_descendant_lock(self):
        self.orphan_writer("run", "success")

    def test_spawn_failure_retains_descendant_lock(self):
        self.orphan_writer("spawn", "failure")

    def test_run_failure_retains_descendant_lock(self):
        self.orphan_writer("run", "failure")

    def test_run_timeout_retains_escaped_descendant_lock(self):
        self.orphan_writer("run", "timeout")

    def test_spawn_indexer_keeps_lock_after_parent_death(self):
        self.orphan_writer("spawn")

    def test_run_flattener_keeps_lock_after_parent_death(self):
        self.orphan_writer("run")


if __name__ == "__main__":
    unittest.main()

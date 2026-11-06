"""Small shared installer/doctor helpers; Python 3.10+, standard library only."""

import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess


SAFE_PATH = "/usr/local/bin:/usr/bin:/bin"
NODE_VERSION = "24.21.0"
BUN_VERSION = "1.3.14"
# Official release SHASUMS256.txt, retrieved 2026-11-06. These are pinned
# metadata, not hashes learned from the downloaded payload.
NODE_URL = "https://nodejs.org/dist/v24.21.0/node-v24.21.0-linux-x64.tar.xz"
NODE_SHA256 = "fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6"
BUN_URL = "https://github.com/oven-sh/bun/releases/download/bun-v1.3.14/bun-linux-x64-baseline.zip"
BUN_SHA256 = "a063908ae08b7852ca10939bbdc6ceed3ddabce8fb9402dce83d65d73b36e6c7"
BUN_LICENSE_URL = "https://raw.githubusercontent.com/oven-sh/bun/bun-v1.3.14/LICENSE.md"
BUN_LICENSE_SHA256 = "2c6160ec8fb853f7e8f97d9b249e756c9b0ac44860a68b6bf4f1b0bcbc5c3741"
PROFILES = ("core", "python-typescript")


def platform_error():
    """Return an unsupported-platform reason, or None for the declared prerequisites."""
    if platform.system() != "Linux" or platform.machine().lower() not in ("x86_64", "amd64"):
        return "Unsupported platform: this candidate supports Linux x86_64 only (WSL is a separate qualification)."
    libc, version = platform.libc_ver()
    if libc != "glibc" or version_tuple(version) < (2, 28, 0):
        return "Unsupported libc: Linux x86_64 with glibc >=2.28 is required; musl is not qualified."
    return None


def version_tuple(value):
    """Parse a tool version into three comparable integers; unknown formats become zero."""
    match = re.search(r"(?:^|\s|v)(\d+)\.(\d+)(?:\.(\d+))?", value)
    return tuple(int(x or 0) for x in match.groups()) if match else (0, 0, 0)


def compatible(name, version):
    """Apply the selected runtime version policy to a version-probe response."""
    value = version_tuple(version)
    if name == "node":
        return value >= (22, 22, 2) and value[0] in (22, 24)
    if name == "bun":
        return (1, 3, 14) <= value < (2, 0, 0)
    if name == "python3":
        return (3, 10, 0) <= value < (4, 0, 0)
    if name == "npm":
        return (10, 0, 0) <= value < (12, 0, 0)
    return False


def within(path, root):
    """Check resolved path containment, treating resolution errors as outside the root."""
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except (ValueError, OSError, RuntimeError):
        return False


def trusted_system(path):
    """Follow symlinks, but never follow a system-looking link into a repo."""
    try:
        resolved = Path(path).resolve(strict=True)
        return (resolved.is_file()
                and any(within(resolved, Path(base)) for base in ("/usr", "/bin"))
                and not any((parent / ".git").exists() for parent in resolved.parents))
    except (OSError, RuntimeError):
        return False


def system_tool(name):
    """Find an executable only through approved system paths and resolved locations."""
    for directory in SAFE_PATH.split(":"):
        found = shutil.which(name, path=directory)
        if found and trusted_system(found):
            return Path(found).resolve()
    return None


def elf_x64(path):
    """Check executable permission and the Linux x86-64 ELF header used by probes."""
    try:
        with Path(path).open("rb") as source:
            header = source.read(20)
        return (len(header) == 20 and header[:6] == b"\x7fELF\x02\x01"
                and int.from_bytes(header[18:20], "little") == 62
                and os.access(path, os.X_OK))
    except OSError:
        return False


def runtime_tool(home, name):
    """Prefer a contained private runtime, falling back to approved system discovery."""
    candidate = home / ".tools/runtime/bin" / name
    try:
        resolved = candidate.resolve(strict=True)
        if ((within(resolved, home / ".tools/runtime") or trusted_system(resolved))
                and resolved.is_file() and os.access(resolved, os.X_OK)):
            return resolved
    except (OSError, RuntimeError):
        pass
    return system_tool(name)


def clean_env(home=None, state=None, network=False):
    # In particular, do not inherit NODE_OPTIONS, PYTHONPATH, shell hooks,
    # npm configuration, repo PATH entries or a real HOME/cache directory.
    """Construct isolated probe/install settings; forward proxy and CA settings only on request."""
    environment = {
        "PATH": (str(home / ".tools/runtime/bin") + ":" if home else "") + SAFE_PATH,
        "XDG_CACHE_HOME": str(state / "cache") if state else "/dev/null",
        "XDG_CONFIG_HOME": str(state / "config") if state else "/dev/null",
        "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
        "PYTHONDONTWRITEBYTECODE": "1", "NO_COLOR": "1",
        "BUN_TELEMETRY_DISABLE": "1",
        "npm_config_userconfig": "/dev/null", "npm_config_globalconfig": "/proc/self/swan-global-npmrc",
        "npm_config_cache": str(state / "npm-cache") if state else "/dev/null",
        "npm_config_logs_max": "0", "npm_config_update_notifier": "false",
    }
    if network:
        for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
                     "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "NPM_CONFIG_CAFILE", "npm_config_cafile"):
            if name in os.environ:
                environment[name] = os.environ[name]
    return environment


def run_checked(command, *, home=None, state=None, cwd="/", timeout=15):
    """Run a bounded command with isolated settings and report nonzero status as failure."""
    result = subprocess.run([str(item) for item in command], cwd=cwd,
                            env=clean_env(home, state), stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=timeout, check=False)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {command[0]}\n{result.stdout[-6000:]}")
    return result.stdout.strip()


def probe(path, name, *, home=None):
    """Report a trusted tool version without consulting repository interpreters or caller PATH."""
    if not path:
        return {"status": "missing", "path": None, "version": None,
                "detail": f"No trusted {name} found in {SAFE_PATH} or the private runtime."}
    if name != "npm" and not elf_x64(path):
        return {"status": "invalid", "path": str(path), "version": None,
                "detail": "Expected an executable Linux x86_64 ELF, not a repository script."}
    if name == "npm":
        node = system_tool("node")
        if not node or not elf_x64(node):
            return {"status": "missing", "path": str(path), "version": None,
                    "detail": "npm needs a trusted system Node interpreter; its PATH shebang is never used."}
        command = [node, path, "--version"]
    else:
        command = [path, "-I", "--version"] if name == "python3" else [path, "--version"]
    try:
        output = run_checked(command, home=home)
        status = "ready" if compatible(name, output) else "incompatible"
        return {"status": status, "path": str(path), "version": output,
                "detail": "Version probe only; feature semantics are not qualification."}
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        return {"status": "failed", "path": str(path), "version": None, "detail": str(error)}


def read_json(path):
    """Load a UTF-8 JSON file, leaving invalid content for the caller to report."""
    return json.loads(Path(path).read_text(encoding="utf-8"))

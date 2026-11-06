#!/usr/bin/env python3
"""Install a verified Swan Linux x86_64 candidate into a NEW user-owned prefix.

Run with Python >=3.10, preferably `python3 -I install.py ...`. The sibling
package_support.py is part of this installer and must be verified with it.
"""

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from package_support import (BUN_SHA256, BUN_URL, BUN_VERSION, BUN_LICENSE_URL, BUN_LICENSE_SHA256, NODE_SHA256, NODE_URL,
                             NODE_VERSION, PROFILES, clean_env, elf_x64,
                             platform_error, probe, run_checked, system_tool, within)


REQUIRED = {"bin/swan", "tools/modules.json", "tools/scip-flatten.ts", "tools/package.json",
            "tools/package-lock.json", "scripts/doctor.py", "scripts/package_support.py",
            "scripts/demo-offline.py", "skills/swan-code-check/SKILL.md", "LICENSE", "NOTICE"}
MAX_UNPACKED = 1024 * 1024 * 1024


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_name(name):
    path = PurePosixPath(name)
    if not name or not path.parts or path.is_absolute() or ".." in path.parts or "\\" in name or "\x00" in name:
        raise ValueError(f"Unsafe archive path: {name!r}")
    return path


def inspect_archive(archive, expected):
    if not re.fullmatch(r"[a-fA-F0-9]{64}", expected):
        raise ValueError("--sha256 must be the reviewed 64-character archive SHA-256.")
    if sha256(archive) != expected.lower():
        raise ValueError("Archive SHA-256 mismatch; no installation was attempted.")
    with tarfile.open(archive, "r:*") as bundle:
        members = bundle.getmembers()
        names = set()
        files = {}
        total = 0
        for member in members:
            name = str(safe_name(member.name))
            if name in names:
                raise ValueError(f"Duplicate archive member: {name}")
            names.add(name)
            if not (member.isfile() or member.isdir()):
                raise ValueError(f"Release archive links/devices are forbidden: {name}")
            if any(part in (".git", "node_modules", "trusted-repos") for part in PurePosixPath(name).parts) or PurePosixPath(name).parts[0] in ("data", ".tools"):
                raise ValueError(f"Release must not contain runtime, map or trust state: {name}")
            total += member.size
            if total > MAX_UNPACKED or len(members) > 20000:
                raise ValueError("Archive exceeds the candidate size/member limit.")
            if member.mode & 0o7000:
                raise ValueError(f"Release member has special permission bits: {name}")
            if member.isfile():
                with bundle.extractfile(member) as source:
                    hasher = hashlib.sha256()
                    for block in iter(lambda: source.read(1024 * 1024), b""):
                        hasher.update(block)
                    digest = hasher.hexdigest()
                files[name] = {"sha256": digest, "size": member.size, "mode": member.mode & 0o777}
        if not REQUIRED <= files.keys():
            raise ValueError("Archive is missing required files: " + ", ".join(sorted(REQUIRED - files.keys())))
        try:
            manifest = json.load(bundle.extractfile("PACKAGE-MANIFEST.json"))
            if not isinstance(manifest, dict) or not isinstance(manifest.get("files"), dict) or not isinstance(manifest.get("platform"), dict):
                raise ValueError("Malformed package manifest object/files/platform.")
            declared = manifest["files"]
            expected_platform = {"os": "linux", "architecture": "x86_64", "executable_format": "ELF64", "endianness": "little"}
            if manifest["schema"] != 1 or any(manifest["platform"].get(key) != value for key, value in expected_platform.items()):
                raise ValueError("Unsupported package manifest schema/platform.")
            actual = {key: value for key, value in files.items() if key != "PACKAGE-MANIFEST.json"}
            if declared != actual or manifest["binary_sha256"] != files["bin/swan"]["sha256"]:
                raise ValueError("Manifest contents differ from the archive files, modes or checksums.")
            if manifest.get("installer_support_sha256") != sha256(Path(__file__).with_name("package_support.py")):
                raise ValueError("Installer support file differs from the package's reviewed helper; use its matching installer/support pair.")
            source = bundle.extractfile("bin/swan")
            header = source.read(20)
            source.close()
            if header[:6] != b"\x7fELF\x02\x01" or len(header) != 20 or int.from_bytes(header[18:20], "little") != 62 or not files["bin/swan"]["mode"] & 0o111:
                raise ValueError("Archive Swan is not an executable Linux x86_64 ELF.")
            return manifest
        except (KeyError, TypeError, json.JSONDecodeError) as error:
            raise ValueError(f"Missing or malformed PACKAGE-MANIFEST.json: {error}") from error


def unpack_release(archive, destination):
    # inspect_archive already rejected links and special files. Use our own
    # extraction so Python 3.10 does not depend on newer tarfile filters.
    with tarfile.open(archive, "r:*") as bundle:
        for member in bundle.getmembers():
            path = destination.joinpath(*safe_name(member.name).parts)
            if member.isdir():
                path.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                path.parent.mkdir(parents=True, exist_ok=True)
                with bundle.extractfile(member) as source, path.open("xb") as target:
                    shutil.copyfileobj(source, target)
                path.chmod(member.mode & 0o755)
            else:
                raise ValueError("Unexpected link/special file during extraction.")


def download(url, destination, expected):
    request = urllib.request.Request(url, headers={"User-Agent": "Swan-candidate-installer/1"})
    with urllib.request.urlopen(request, timeout=60) as source, destination.open("xb") as target:
        if not source.url.startswith("https://"):
            raise ValueError("Refusing a non-HTTPS download redirect.")
        shutil.copyfileobj(source, target)
    if sha256(destination) != expected:
        raise ValueError(f"Pinned runtime checksum mismatch: {url}")


def unpack_node(archive, runtime):
    root = f"node-v{NODE_VERSION}-linux-x64"
    deferred_links = []
    total = 0
    with tarfile.open(archive, "r:xz") as bundle:
        for member in bundle.getmembers():
            parts = safe_name(member.name).parts
            if parts[0] != root:
                raise ValueError("Unexpected Node archive root.")
            path = runtime.joinpath(*parts)
            total += member.size
            if total > MAX_UNPACKED:
                raise ValueError("Node archive exceeds the unpacked size limit.")
            if member.isdir():
                path.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                path.parent.mkdir(parents=True, exist_ok=True)
                with bundle.extractfile(member) as source, path.open("xb") as target:
                    shutil.copyfileobj(source, target)
                path.chmod(member.mode & 0o755)
            elif member.issym():
                target = Path(member.linkname)
                if target.is_absolute() or not within(path.parent / target, runtime / root):
                    raise ValueError("Node archive symlink escapes its runtime.")
                deferred_links.append((path, member.linkname))
            else:
                raise ValueError("Node archive has an unexpected special/hardlinked file.")
    for path, target in deferred_links:
        path.symlink_to(target)
    return runtime / root


def install_runtimes(home, state, detected):
    runtime = home / ".tools/runtime"
    commands = runtime / "bin"
    commands.mkdir(parents=True)
    if detected["node"]["status"] == "ready" and detected["npm"]["status"] == "ready":
        for name in ("node", "npm", "npx"):
            path = system_tool(name)
            if path:
                (commands / name).symlink_to(path)
    else:
        archive = state / "node.tar.xz"
        download(NODE_URL, archive, NODE_SHA256)
        vendor = unpack_node(archive, runtime)
        if not elf_x64(vendor / "bin/node"):
            raise ValueError("Downloaded Node has an incompatible executable.")
        for name in ("node", "npm", "npx"):
            (commands / name).symlink_to(f"../{vendor.name}/bin/{name}")
    if detected["bun"]["status"] == "ready":
        (commands / "bun").symlink_to(detected["bun"]["path"])
    else:
        archive = state / "bun.zip"
        download(BUN_URL, archive, BUN_SHA256)
        vendor = runtime / f"bun-v{BUN_VERSION}"
        vendor.mkdir()
        with zipfile.ZipFile(archive) as bundle:
            info = bundle.getinfo("bun-linux-x64-baseline/bun")
            if info.file_size > MAX_UNPACKED:
                raise ValueError("Bun executable exceeds the unpacked size limit.")
            with bundle.open(info) as source, (vendor / "bun").open("xb") as target:
                shutil.copyfileobj(source, target)
        (vendor / "bun").chmod(0o755)
        if not elf_x64(vendor / "bun"):
            raise ValueError("Downloaded Bun has an incompatible executable.")
        download(BUN_LICENSE_URL, vendor / "LICENSE.md", BUN_LICENSE_SHA256)
        (commands / "bun").symlink_to(f"../{vendor.name}/bun")


def atomic_activate(stage, prefix):
    # os.rename may replace an empty directory created concurrently. Linux's
    # RENAME_NOREPLACE gives activation the promised no-overwrite semantics.
    libc = ctypes.CDLL(None, use_errno=True)
    rename = getattr(libc, "renameat2", None)
    if rename is None:
        raise RuntimeError("Atomic no-overwrite activation requires glibc renameat2; destination was not changed.")
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(-100, os.fsencode(stage), -100, os.fsencode(prefix), 1) != 0:
        error = ctypes.get_errno()
        raise OSError(error, "Could not activate without replacing the destination: " + os.strerror(error), str(prefix))


def plan(options):
    if sys.version_info < (3, 10):
        raise ValueError("System Python >=3.10 is required.")
    error = platform_error()
    if error:
        raise ValueError(error)
    prefix = options.prefix
    if not prefix.is_absolute() or prefix.name in ("", ".", ".."):
        raise ValueError("--prefix must name a new absolute installation directory.")
    prefix = prefix.parent.resolve(strict=True) / prefix.name
    if os.path.lexists(prefix):
        raise ValueError(f"Destination already exists (including empty directories); preserved unchanged: {prefix}")
    manifest = inspect_archive(options.archive, options.sha256)
    detected = {name: probe(system_tool(name), name) for name in ("python3", "node", "bun", "npm")}
    if detected["python3"]["status"] != "ready":
        raise ValueError("System Python >=3.10 is required for the installer/doctor. Install it with your OS tools; no project interpreter will be used.")
    downloads = []
    if options.profile == "python-typescript":
        if detected["node"]["status"] != "ready" or detected["npm"]["status"] != "ready":
            downloads.append({"name": "Node + npm", "version": NODE_VERSION, "url": NODE_URL, "sha256": NODE_SHA256})
        if detected["bun"]["status"] != "ready":
            downloads.append({"name": "Bun baseline", "version": BUN_VERSION, "url": BUN_URL, "sha256": BUN_SHA256})
            downloads.append({"name": "Bun pinned license/linked-library notices", "url": BUN_LICENSE_URL, "sha256": BUN_LICENSE_SHA256})
        downloads.append({"name": "Frozen npm tool set", "source": "tools/package-lock.json", "command": "npm ci --ignore-scripts --no-audit --no-fund"})
    return prefix, manifest, detected, {"prefix": str(prefix), "profile": options.profile,
        "archive": str(options.archive.resolve()), "archive_sha256": options.sha256.lower(),
        "source_revision": manifest.get("source_revision"), "detected": detected, "downloads": downloads,
        "unselected": ["Python ruff/pytest", "Rust", "Java/Kotlin", "C#", "CUDA/C++", "game/shader adapters"],
        "writes": "New sibling staging and the new prefix only; no sudo, global configuration or repository trust."}


def install(options):
    prefix, manifest, detected, summary = plan(options)
    print(json.dumps(summary, indent=2), flush=True)
    if options.dry_run:
        print("Dry run complete: no files written or downloads performed.")
        return
    # Hold the exact checked archive open by copying it to our own staging,
    # then verify again. A caller replacing its archive cannot change inputs.
    with tempfile.TemporaryDirectory(prefix=".swan-install-", dir=prefix.parent) as temporary:
        stage_parent = Path(temporary)
        stage = stage_parent / "home"
        stage.mkdir()
        archive = stage_parent / "candidate.tar"
        shutil.copyfile(options.archive, archive)
        inspect_archive(archive, options.sha256)
        unpack_release(archive, stage)
        state = stage / ".install-state"
        state.mkdir()
        python = system_tool("python3")
        if not python or probe(python, "python3")["status"] != "ready":
            raise ValueError("A safe system Python >=3.10 is required to run the staged smoke checks.")
        if options.profile == "python-typescript":
            install_runtimes(stage, state, detected)
            node = stage / ".tools/runtime/bin/node"
            npm = (stage / ".tools/runtime/bin/npm").resolve(strict=True)
            env = clean_env(stage, state, network=True)
            result = subprocess.run([str(node), str(npm), "ci", "--ignore-scripts", "--no-audit", "--no-fund"],
                                    cwd=stage / "tools", env=env, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=600)
            if result.returncode:
                raise RuntimeError("Frozen npm install failed:\n" + result.stdout[-6000:])
            if sha256(stage / "tools/package-lock.json") != manifest["files"]["tools/package-lock.json"]["sha256"]:
                raise RuntimeError("Frozen npm install unexpectedly changed the reviewed lockfile.")
            print(result.stdout.strip(), flush=True)
        print(run_checked([python, "-I", stage / "scripts/doctor.py", "--home", stage,
                           "--profile", options.profile, "--json"], home=stage, timeout=120), flush=True)
        print(run_checked([python, "-I", stage / "scripts/demo-offline.py", "--binary", stage / "bin/swan",
                           "--output-parent", state / "smoke"], home=stage, state=state, timeout=120), flush=True)
        shutil.rmtree(state)
        receipt = {"stage": "installed candidate; not production", "profile": options.profile,
                   "source_revision": manifest.get("source_revision"), "archive_sha256": options.sha256.lower(),
                   "checks": ["read-only selected dependency probes", "offline synthetic-row semantic smoke"],
                   "not_qualified": "Real selected-language indexing, diagnostics and trust controls require the separate qualification receipt."}
        (stage / "INSTALLATION.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        atomic_activate(stage, prefix)
    print(f"Installed candidate: {prefix}\nExecutable: {prefix / 'bin/swan'}\nPortable skill: {prefix / 'skills/swan-code-check'}")
    print("Register those paths explicitly in your agent if desired. No agent configuration or repository trust was changed.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--profile", choices=PROFILES, default="python-typescript")
    parser.add_argument("--dry-run", action="store_true")
    options = parser.parse_args(argv)
    try:
        install(options)
        return 0
    except (OSError, ValueError, RuntimeError, tarfile.TarError, zipfile.BadZipFile, subprocess.TimeoutExpired) as failure:
        print(f"Installation refused/failed: {failure}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

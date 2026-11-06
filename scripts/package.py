#!/usr/bin/env python3
"""Export an already-built Linux x86_64 Swan candidate; never build or publish.

The build receipt is an operator's source/build attestation, not independent
proof of compilation. It must bind the exact clean source revision to the
binary hash. Runtime qualification and official release status are separate.
"""

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tarfile


ARCHIVE = "swan-linux-x86_64.tar.gz"
MANIFEST = "PACKAGE-MANIFEST.json"
RUNTIME_FILES = (
    "LICENSE", "NOTICE", "docs/install.md", "tools/modules.json", "tools/scip-flatten.ts",
    "tools/package.json", "tools/package-lock.json", "scripts/doctor.py",
    "scripts/package_support.py", "scripts/demo-offline.py",
)
OPTIONAL_FILES = ("scripts/verify-live-trust.py",)
INSTALLER = "scripts/install.py"


class PackageError(ValueError):
    pass


def sha256(data):
    """Return the SHA-256 identity used to bind reviewed inputs to outputs."""
    return hashlib.sha256(data).hexdigest()


def json_bytes(value):
    """Encode stable JSON bytes for reproducible manifests and checksums."""
    return (json.dumps(value, sort_keys=True, indent=2) + "\n").encode()


def safe_relative(value):
    """Require a portable relative inventory path without traversal or control characters."""
    path = PurePosixPath(value)
    if (not value or path.is_absolute() or "\\" in value or ":" in value
            or any(part in ("", ".", "..") for part in value.split("/"))
            or any(ord(char) < 32 or ord(char) == 127 for char in value)):
        raise PackageError("unsafe relative path: " + repr(value))
    return path


def regular_file(path):
    """Reject symlinks in every input component, and nonregular payloads."""
    path = Path(os.path.abspath(path))
    for component in (path, *path.parents):
        if component.is_symlink():
            raise PackageError("symlink input is not permitted: " + str(component))
    try:
        mode = path.stat().st_mode
    except OSError as error:
        raise PackageError("missing input: " + str(path)) from error
    if not stat.S_ISREG(mode):
        raise PackageError("input must be a regular file: " + str(path))
    return path.read_bytes(), stat.S_IMODE(mode) & 0o777


def git(root, *arguments):
    """Run Git against this checkout and fail if the requested operation fails."""
    result = subprocess.run(["git", "-C", str(root), *arguments],
                            capture_output=True, check=False)
    if result.returncode:
        raise PackageError("cannot verify Git source: " + result.stderr.decode(errors="replace").strip())
    return result.stdout


def source_snapshot(root, revision):
    """Require the exact clean Git revision and return its tracked file inventory."""
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", revision):
        raise PackageError("source revision must be a full lowercase Git commit hash")
    head = git(root, "rev-parse", "HEAD").decode().strip()
    if head != revision:
        raise PackageError("source revision does not match checked-out HEAD")
    # Includes staged/unstaged changes, deletions, and dirty submodules.
    if git(root, "status", "--porcelain=v1", "--untracked-files=no"):
        raise PackageError("tracked source is dirty; commit the candidate before export")
    tracked = {item.decode() for item in git(root, "ls-files", "-z").split(b"\0") if item}
    for item in tracked:
        safe_relative(item)
    return tracked


def validate_elf(data, mode):
    """Reject non-executable or malformed ELF64 x86-64 binaries before export."""
    if (len(data) < 64 or data[:7] != b"\x7fELF\x02\x01\x01"
            or data[7] not in (0, 3)
            or int.from_bytes(data[16:18], "little") not in (2, 3)
            or int.from_bytes(data[18:20], "little") != 62
            or int.from_bytes(data[20:24], "little") != 1
            or int.from_bytes(data[52:54], "little") != 64):
        raise PackageError("binary must be a Linux-compatible ELF64 little-endian x86_64 executable")
    program_offset = int.from_bytes(data[32:40], "little")
    program_size = int.from_bytes(data[54:56], "little")
    program_count = int.from_bytes(data[56:58], "little")
    if (program_size != 56 or program_count == 0 or program_offset < 64
            or program_offset + program_size * program_count > len(data)):
        raise PackageError("binary has an invalid or truncated ELF64 program table")
    loadable = False
    for index in range(program_count):
        entry = data[program_offset + index * program_size:program_offset + (index + 1) * program_size]
        file_offset = int.from_bytes(entry[8:16], "little")
        file_size = int.from_bytes(entry[32:40], "little")
        memory_size = int.from_bytes(entry[40:48], "little")
        if file_offset + file_size > len(data):
            raise PackageError("binary has a truncated ELF64 segment")
        if int.from_bytes(entry[:4], "little") == 1:
            if file_size > memory_size:
                raise PackageError("binary has an invalid ELF64 load segment")
            loadable = True
    if not loadable:
        raise PackageError("binary has no ELF64 load segment")
    if not mode & 0o111:
        raise PackageError("binary is not executable")


def collect_licenses(directory, required):
    """Collect original regular-file notices and require every explicitly named license."""
    directory = Path(os.path.abspath(directory))
    if directory.is_symlink() or not directory.is_dir():
        raise PackageError("licenses must be a directory without symlinks")
    result = {}
    for path in sorted(directory.rglob("*")):
        relative = path.relative_to(directory).as_posix()
        safe_relative(relative)
        if path.is_symlink():
            raise PackageError("symlink license is not permitted: " + relative)
        if path.is_dir():
            continue
        result[relative] = regular_file(path)
    if not result:
        raise PackageError("licenses directory must contain the compiled third-party license notices")
    for name in required:
        safe_relative(name)
        if name not in result:
            raise PackageError("required license is missing: " + name)
    return {"licenses/" + name: value for name, value in result.items()}


def build_package(root, binary, output, revision, receipt_path, licenses, required_licenses=()):
    """Export a deterministic candidate bound to its clean source and binary receipt."""
    root = Path(root).resolve()
    output = Path(os.path.abspath(output))
    if output.exists() or output.is_symlink():
        raise PackageError("output destination already exists: " + str(output))
    if not output.parent.is_dir():
        raise PackageError("output parent must already exist: " + str(output.parent))
    tracked = source_snapshot(root, revision)
    binary_data, binary_mode = regular_file(binary)
    validate_elf(binary_data, binary_mode)
    receipt_data, _ = regular_file(receipt_path)
    try:
        receipt = json.loads(receipt_data)
    except (ValueError, UnicodeError) as error:
        raise PackageError("build receipt must contain JSON") from error
    if (not isinstance(receipt, dict) or receipt.get("source_revision") != revision
            or receipt.get("binary_sha256") != sha256(binary_data)):
        raise PackageError("build receipt source revision or binary checksum does not match")
    payload = {"bin/swan": (binary_data, binary_mode), "BUILD-RECEIPT.json": (receipt_data, 0o644)}
    skill_files = sorted(name for name in tracked if name.startswith("skills/swan-code-check/"))
    if "skills/swan-code-check/SKILL.md" not in skill_files:
        raise PackageError("tracked canonical skill is missing")
    files = [*RUNTIME_FILES, *skill_files]
    files.extend(name for name in OPTIONAL_FILES if name in tracked)
    for name in [*files, INSTALLER]:
        if name not in tracked:
            raise PackageError("required runtime file is not tracked: " + name)
    for name in files:
        payload[name] = regular_file(root / name)
    installer, installer_mode = regular_file(root / INSTALLER)
    payload.update(collect_licenses(licenses, required_licenses))
    manifest = {
        "schema": 1,
        "artifact_status": "candidate",
        "qualification": "archive export only; build receipt is an operator attestation; no official release or runtime qualification implied",
        "platform": {"os": "linux", "architecture": "x86_64", "executable_format": "ELF64", "endianness": "little"},
        "source_revision": revision,
        "tracked_source_clean": True,
        "binary_sha256": sha256(binary_data),
        "installer_sha256": sha256(installer),
        "installer_support_sha256": sha256(payload["scripts/package_support.py"][0]),
        "files": {name: {"sha256": sha256(data), "size": len(data), "mode": mode}
                  for name, (data, mode) in sorted(payload.items())},
    }
    payload[MANIFEST] = (json_bytes(manifest), 0o644)
    # Recheck after reading the snapshot. Untracked files never enter it.
    if source_snapshot(root, revision) != tracked:
        raise PackageError("tracked source inventory changed during export")
    try:
        output.mkdir()  # Exclusive creation: never replace an existing destination.
    except FileExistsError as error:
        raise PackageError("output destination already exists: " + str(output)) from error
    try:
        archive_path = output / ARCHIVE
        with archive_path.open("xb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                    for name, (data, mode) in sorted(payload.items()):
                        entry = tarfile.TarInfo(name)
                        entry.size, entry.mode, entry.mtime = len(data), mode, 0
                        entry.uid = entry.gid = 0
                        entry.uname = entry.gname = ""
                        archive.addfile(entry, io.BytesIO(data))
        (output / "install.py").write_bytes(installer)
        (output / "install.py").chmod(installer_mode)
        support, support_mode = payload["scripts/package_support.py"]
        (output / "package_support.py").write_bytes(support)
        (output / "package_support.py").chmod(support_mode)
        for name in (ARCHIVE, "install.py", "package_support.py"):
            (output / (name + ".sha256")).write_text(sha256((output / name).read_bytes()) + "  " + name + "\n")
    except BaseException:
        shutil.rmtree(output)
        raise
    return manifest


def main():
    """Parse command-line options and return or report the operation status."""
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=root / "bin/swan")
    parser.add_argument("--output", type=Path, required=True, help="New export directory; parent must exist")
    parser.add_argument("--source-revision", required=True, help="Full committed source hash matching HEAD")
    parser.add_argument("--build-receipt", type=Path, required=True,
                        help="JSON with source_revision and binary_sha256 from the completed build")
    parser.add_argument("--licenses", type=Path, required=True, help="Curated compiled third-party license directory")
    parser.add_argument("--require-license", action="append", default=[], metavar="RELATIVE_PATH",
                        help="Refuse export if this expected license is missing (repeatable)")
    options = parser.parse_args()
    try:
        build_package(root, options.binary, options.output, options.source_revision,
                      options.build_receipt, options.licenses, options.require_license)
    except (PackageError, OSError) as error:
        parser.exit(1, "package: " + str(error) + "\n")
    print("Candidate exported: " + str(options.output / ARCHIVE))
    print("Archive export does not qualify an installation or publish a release.")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""NoCloud instance initialization — replaces cloud-init.

Mounts the Proxmox CIDATA ISO, parses the cloud-init user-data YAML,
and applies: hostname, SSH authorized keys, and write_files directives.

Uses only Python standard library (no PyYAML — it's not in stdlib).
Handles the minimal YAML subset that cloud-init user-data uses.
"""

import base64
import os
import pathlib
import stat
import subprocess
import sys

CIDATA_MOUNT = "/run/cidata"


# ── Minimal YAML parser for cloud-init user-data ────────────────────
# Cloud-init user-data is a small, predictable subset of YAML.
# We parse: scalars, sequences (- items), and mappings (key: value),
# with block scalar support (content: |).


def parse_user_data(text):
    """Parse cloud-init user-data into a dict.

    Handles the subset used by our templates:
      hostname: <string>
      ssh_authorized_keys:
        - <key1>
        - <key2>
      write_files:
        - path: <path>
          content: |
            <multiline>
          permissions: '<octal>'
          owner: <owner>
    """
    lines = text.splitlines()
    result = {}
    i = 0

    while i < len(lines):
        line = lines[i]

        # Skip comments and blank lines
        if not line.strip() or line.strip().startswith("#"):
            i += 1
            continue

        # Top-level key: value (no leading whitespace)
        if not line[0].isspace() and ":" in line:
            key, _, value = line.partition(":")
            key = key.strip()
            value = value.strip()

            if value:
                # Simple scalar: "hostname: myhost"
                # Strip surrounding quotes
                if (value.startswith("'") and value.endswith("'")) or \
                   (value.startswith('"') and value.endswith('"')):
                    value = value[1:-1]
                result[key] = value
                i += 1
            else:
                # Block: either a sequence (- items) or mapping list (- key: val)
                i += 1
                items = []
                while i < len(lines):
                    child = lines[i]
                    if not child.strip():
                        i += 1
                        continue
                    # If not indented, we've left this block
                    if child[0] != " " and child[0] != "\t":
                        break

                    stripped = child.strip()
                    if stripped.startswith("- ") and ":" not in stripped[2:]:
                        # Simple sequence item: "  - ssh-ed25519 ..."
                        items.append(stripped[2:].strip())
                        i += 1
                    elif stripped.startswith("- ") and ":" in stripped[2:]:
                        # Mapping sequence item: "  - path: /foo"
                        mapping = {}
                        first_kv = stripped[2:]
                        mk, _, mv = first_kv.partition(":")
                        mk = mk.strip()
                        mv = mv.strip()

                        # Check for block scalar (content: |)
                        if mv == "|":
                            # Collect indented block
                            i += 1
                            block_lines = []
                            # Determine indent of first content line
                            if i < len(lines) and lines[i].strip():
                                block_indent = len(lines[i]) - len(lines[i].lstrip())
                            else:
                                block_indent = 0
                            while i < len(lines):
                                bl = lines[i]
                                if bl.strip() == "":
                                    block_lines.append("")
                                    i += 1
                                    continue
                                bl_indent = len(bl) - len(bl.lstrip())
                                if bl_indent >= block_indent and block_indent > 0:
                                    block_lines.append(bl[block_indent:])
                                    i += 1
                                else:
                                    break
                            # Remove trailing empty lines
                            while block_lines and block_lines[-1] == "":
                                block_lines.pop()
                            mapping[mk] = "\n".join(block_lines) + "\n"
                        else:
                            # Strip quotes from value
                            if (mv.startswith("'") and mv.endswith("'")) or \
                               (mv.startswith('"') and mv.endswith('"')):
                                mv = mv[1:-1]
                            mapping[mk] = mv
                            i += 1

                        # Collect remaining keys in this mapping item
                        # (same indent level as the first key after "- ")
                        while i < len(lines):
                            ml = lines[i]
                            if not ml.strip():
                                i += 1
                                continue
                            ml_stripped = ml.strip()
                            # New sequence item or back to top level
                            if ml_stripped.startswith("- ") or not ml[0].isspace():
                                break
                            if ":" in ml_stripped:
                                mk2, _, mv2 = ml_stripped.partition(":")
                                mk2 = mk2.strip()
                                mv2 = mv2.strip()
                                if mv2 == "|":
                                    i += 1
                                    block_lines = []
                                    if i < len(lines) and lines[i].strip():
                                        block_indent = len(lines[i]) - len(lines[i].lstrip())
                                    else:
                                        block_indent = 0
                                    while i < len(lines):
                                        bl = lines[i]
                                        if bl.strip() == "":
                                            block_lines.append("")
                                            i += 1
                                            continue
                                        bl_indent = len(bl) - len(bl.lstrip())
                                        if bl_indent >= block_indent and block_indent > 0:
                                            block_lines.append(bl[block_indent:])
                                            i += 1
                                        else:
                                            break
                                    while block_lines and block_lines[-1] == "":
                                        block_lines.pop()
                                    mapping[mk2] = "\n".join(block_lines) + "\n"
                                else:
                                    if (mv2.startswith("'") and mv2.endswith("'")) or \
                                       (mv2.startswith('"') and mv2.endswith('"')):
                                        mv2 = mv2[1:-1]
                                    mapping[mk2] = mv2
                                    i += 1
                            else:
                                i += 1
                        items.append(mapping)
                    else:
                        i += 1

                result[key] = items
        else:
            i += 1

    return result


# ── Mount/unmount CIDATA ────────────────────────────────────────────


def mount_cidata():
    """Mount the CIDATA ISO and return the mount path."""
    os.makedirs(CIDATA_MOUNT, exist_ok=True)

    # Already mounted?
    ret = subprocess.run(["mountpoint", "-q", CIDATA_MOUNT],
                         capture_output=True)
    if ret.returncode == 0:
        return CIDATA_MOUNT

    # Find the cidata device
    ret = subprocess.run(["blkid", "-L", "cidata"],
                         capture_output=True, text=True)
    device = ret.stdout.strip()
    if not device:
        device = "/dev/sr0"  # fallback

    subprocess.run(["mount", "-o", "ro", "-t", "iso9660", device, CIDATA_MOUNT],
                   check=True)
    print(f"Mounted {device} at {CIDATA_MOUNT}")
    return CIDATA_MOUNT


def unmount_cidata():
    """Unmount the CIDATA ISO."""
    subprocess.run(["umount", CIDATA_MOUNT], capture_output=True)


# ── Directive handlers ──────────────────────────────────────────────


def handle_hostname(data):
    """Set hostname from user-data."""
    hostname = data.get("hostname")
    if not hostname:
        return

    # On NixOS, /etc/hostname is read-only and hostnamectl is blocked.
    # Use the hostname command to set the runtime hostname directly.
    subprocess.run(["hostname", hostname], check=True)
    print(f"Hostname set to: {hostname}")


def handle_ssh_keys(data):
    """Write SSH authorized keys, avoiding duplicates."""
    keys = []

    # Top-level ssh_authorized_keys
    top_keys = data.get("ssh_authorized_keys", [])
    if isinstance(top_keys, list):
        keys.extend(top_keys)

    # users[*].ssh_authorized_keys (Proxmox sometimes uses this format)
    users = data.get("users", [])
    if isinstance(users, list):
        for user in users:
            if isinstance(user, dict):
                user_keys = user.get("ssh_authorized_keys", [])
                if isinstance(user_keys, list):
                    keys.extend(user_keys)

    if not keys:
        return

    ssh_dir = pathlib.Path("/root/.ssh")
    ssh_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(ssh_dir, stat.S_IRWXU)  # 700

    auth_keys_path = ssh_dir / "authorized_keys"

    # Read existing keys to avoid duplicates
    existing = set()
    if auth_keys_path.exists():
        existing = set(auth_keys_path.read_text().splitlines())

    new_keys = [k for k in keys if k and k not in existing]
    if new_keys:
        with open(auth_keys_path, "a") as f:
            for key in new_keys:
                f.write(key + "\n")
        print(f"SSH: added {len(new_keys)} key(s)")
    else:
        print("SSH: all keys already present")

    os.chmod(auth_keys_path, stat.S_IRUSR | stat.S_IWUSR)  # 600


def handle_write_files(data):
    """Process write_files directives."""
    files = data.get("write_files", [])
    if not isinstance(files, list):
        return

    for entry in files:
        if not isinstance(entry, dict):
            continue

        path = entry.get("path")
        content = entry.get("content", "")
        encoding = entry.get("encoding", "")
        permissions = entry.get("permissions", "0644")

        if not path:
            print(f"write_files: skipping entry with no path")
            continue

        # Create parent directories
        p = pathlib.Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)

        # Handle encoding
        if encoding in ("b64", "base64"):
            file_bytes = base64.b64decode(content)
            p.write_bytes(file_bytes)
        else:
            # Plain text — strip single trailing newline from block scalar
            # if content ends with \n (YAML block scalar adds one)
            p.write_text(content)

        # Set permissions
        try:
            mode = int(permissions, 8)
            os.chmod(path, mode)
        except (ValueError, TypeError):
            os.chmod(path, 0o644)

        print(f"write_files: wrote {path} (mode {permissions})")


# ── Main ────────────────────────────────────────────────────────────


def main():
    try:
        mount_path = mount_cidata()
    except Exception as e:
        print(f"FATAL: cannot mount CIDATA: {e}", file=sys.stderr)
        return 1

    try:
        user_data_path = os.path.join(mount_path, "user-data")
        if not os.path.exists(user_data_path):
            print("No user-data found on CIDATA, nothing to do")
            return 0

        text = pathlib.Path(user_data_path).read_text()
        data = parse_user_data(text)

        errors = 0
        for handler in (handle_hostname, handle_ssh_keys, handle_write_files):
            try:
                handler(data)
            except Exception as e:
                print(f"ERROR in {handler.__name__}: {e}", file=sys.stderr)
                errors += 1

        return 1 if errors else 0
    finally:
        unmount_cidata()


if __name__ == "__main__":
    sys.exit(main())

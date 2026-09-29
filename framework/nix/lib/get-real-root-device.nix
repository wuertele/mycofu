{ pkgs }:

pkgs.writeShellScript "get-real-root-device" ''
  set -euo pipefail

  ROOT_SOURCE=$(findmnt -n -o SOURCE /)
  if [ "$ROOT_SOURCE" = "overlay" ]; then
    # Under overlay root, /mnt-real-root is a ro bind-mount (safety net).
    # /mnt-real-root-rw is the actual rw ext4. Use --nofsroot to get the
    # plain device path from either (findmnt returns bind-style output
    # like /dev/sda1[/subdir] without this flag).
    if mountpoint -q /mnt-real-root-rw 2>/dev/null; then
      ROOT_SOURCE=$(findmnt -n -o SOURCE --nofsroot /mnt-real-root-rw)
    else
      ROOT_SOURCE=$(findmnt -n -o SOURCE --nofsroot /mnt-real-root)
    fi
  fi

  if [ -z "$ROOT_SOURCE" ]; then
    echo "ERROR: unable to determine the real root device" >&2
    exit 1
  fi

  readlink -f "$ROOT_SOURCE"
''

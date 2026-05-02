#!/usr/bin/env bash
# vdb-state-lib.sh — Common vdb real-state detection for backup/restore flows.
#
# These helpers intentionally treat a freshly bootstrapped workstation /home
# (user dir + ~/.ssh/authorized_keys only) as "empty". That keeps first-boot
# SSH access workable without letting the bootstrap skeleton masquerade as
# restored precious state in backup/rebuild/restore decisions.

vdb_state_mount_points_for_label() {
  local label="$1"

  case "$label" in
    gitlab)
      printf '%s\n' "/var/lib/gitlab"
      ;;
    vault*)
      printf '%s\n' "/var/lib/vault"
      ;;
    influxdb*)
      printf '%s\n' "/var/lib/influxdb2"
      ;;
    roon*)
      printf '%s\n' "/var/lib/roon-server"
      ;;
    grafana*)
      printf '%s\n' "/var/lib/grafana"
      ;;
    testapp*)
      printf '%s\n' "/var/lib/testapp"
      ;;
    workstation*)
      printf '%s\n' "/home"
      ;;
    *)
      printf '%s\n' "/var/lib/data" "/var/lib"
      ;;
  esac
}

vdb_state_probe_script_for_label() {
  local label="$1"
  local mount_point=""

  case "$label" in
    workstation*)
      cat <<'EOF'
if [ ! -d /home ]; then
  exit 1
fi

USERNAME="$(tr -d '\r\n' < /run/secrets/workstation/username 2>/dev/null || true)"

for entry in /home/* /home/.[!.]* /home/..?*; do
  [ -e "$entry" ] || continue
  base="$(basename "$entry")"
  [ "$base" = "lost+found" ] && continue

  if [ -n "$USERNAME" ] && [ "$base" = "$USERNAME" ] && [ -d "$entry" ]; then
    if find "$entry" -mindepth 1 -maxdepth 1 ! -name '.ssh' -print -quit 2>/dev/null | grep -q .; then
      echo "/home"
      exit 0
    fi

    if [ -d "$entry/.ssh" ]; then
      if find "$entry/.ssh" -mindepth 1 -maxdepth 1 ! -name 'authorized_keys' -print -quit 2>/dev/null | grep -q .; then
        echo "/home"
        exit 0
      fi

      if [ ! -f "$entry/.ssh/authorized_keys" ]; then
        echo "/home"
        exit 0
      fi
    fi

    continue
  fi

  echo "/home"
  exit 0
done

exit 1
EOF
      ;;
    *)
      printf 'for mp in'
      while IFS= read -r mount_point; do
        [[ -n "$mount_point" ]] || continue
        printf " '%s'" "$mount_point"
      done < <(vdb_state_mount_points_for_label "$label")
      cat <<'EOF'
; do
  [ -d "$mp" ] || continue
  if find "$mp" -mindepth 1 -maxdepth 1 ! -name 'lost+found' -print -quit 2>/dev/null | grep -q .; then
    echo "$mp"
    exit 0
  fi
done

exit 1
EOF
      ;;
  esac
}

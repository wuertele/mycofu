#!/usr/bin/env bash
# ssh-refresh.sh — Remove stale host key and accept new one on first connect.
# Use after any VM recreation that changes the SSH host key.
#
# Usage: ssh-refresh.sh <ip-or-hostname> [additional ssh args...]
#
# Example: ssh-refresh.sh 192.0.2.50
#          ssh-refresh.sh 192.0.2.50 "systemctl status pdns"

set -euo pipefail

HOST="${1:?Usage: ssh-refresh.sh <ip-or-hostname> [ssh-args...]}"
shift

echo "Removing stale host key for $HOST..."
ssh-keygen -R "$HOST" 2>/dev/null || true

echo "Connecting (accepting new host key)..."
ssh -o StrictHostKeyChecking=accept-new root@"$HOST" "$@"

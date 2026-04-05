#!/usr/bin/env bash
# SSH helper for running commands on Proxmox nodes

ssh_node() {
  local ip="$1"
  shift
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR \
      "root@${ip}" "$@" 2>/dev/null
}

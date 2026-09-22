#!/usr/bin/env python3
"""Load DNS zone data from CIDATA JSON into PowerDNS via the localhost API.

Reads a zone-data.json file (delivered via CIDATA write_files) and
reconciles PowerDNS state to match. Idempotent: running multiple times
produces no errors and no changes on subsequent runs.

Usage:
    python3 load-zones.py /run/cidata/zone-data.json

Expected JSON format:
    {
        "zone": "prod.example.com",
        "records": [
            {"name": "@", "type": "SOA", "content": "dns1.prod.example.com. ..."},
            {"name": "@", "type": "NS", "content": "dns1.prod.example.com."},
            {"name": "vault", "type": "A", "content": "10.0.10.52"},
            ...
        ]
    }
"""

import json
import sys
import urllib.request
import urllib.error
from collections import defaultdict

API_BASE = "http://127.0.0.1:8081/api/v1/servers/localhost"
API_KEY = ""


def api_request(path, method="GET", data=None):
    """Make a PowerDNS API request."""
    url = f"{API_BASE}{path}"
    headers = {"X-API-Key": API_KEY}
    body = None
    if data is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(data).encode()

    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            if resp.status == 204:
                return None
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        body_text = e.read().decode() if e.fp else ""
        print(f"  API error: {method} {path} -> {e.code}: {body_text}", file=sys.stderr)
        raise


def ensure_zone(zone_dot, nameservers):
    """Create zone if it doesn't exist."""
    result = api_request(f"/zones/{zone_dot}")
    if result is not None:
        print(f"  Zone {zone_dot} already exists")
        return

    print(f"  Creating zone {zone_dot}...")
    api_request("/zones", method="POST", data={
        "name": zone_dot,
        "kind": "Native",
        "nameservers": nameservers,
        "soa_edit_api": "INCEPTION-INCREMENT",
    })
    print(f"  Zone created")


def build_rrsets(zone_dot, records):
    """Group records by (name, type) and build PATCH rrsets payload."""
    groups = defaultdict(list)

    for record in records:
        name = record["name"]
        rtype = record["type"]
        content = record["content"]

        # Convert short name to FQDN
        if name == "@":
            fqdn = zone_dot
        elif name.endswith("."):
            fqdn = name
        else:
            fqdn = f"{name}.{zone_dot}"

        # Ensure trailing dots on NS/CNAME/MX content
        if rtype in ("NS", "CNAME", "MX") and not content.endswith("."):
            content = content + "."

        # Quote TXT records
        if rtype == "TXT" and not content.startswith('"'):
            content = f'"{content}"'

        groups[(fqdn, rtype)].append({
            "content": content,
            "disabled": False,
        })

    rrsets = []
    for (fqdn, rtype), recs in sorted(groups.items()):
        rrsets.append({
            "name": fqdn,
            "type": rtype,
            "ttl": 300,
            "changetype": "REPLACE",
            "records": recs,
        })

    return {"rrsets": rrsets}


def main():
    global API_KEY

    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <zone-data.json>", file=sys.stderr)
        sys.exit(2)

    zone_file = sys.argv[1]

    # Read API key
    try:
        with open("/run/pdns/conf.d/api-key.conf") as f:
            for line in f:
                if line.startswith("api-key="):
                    API_KEY = line.strip().split("=", 1)[1]
    except FileNotFoundError:
        print("ERROR: /run/pdns/conf.d/api-key.conf not found", file=sys.stderr)
        sys.exit(1)

    if not API_KEY:
        print("ERROR: Could not read API key", file=sys.stderr)
        sys.exit(1)

    # Read zone data
    with open(zone_file) as f:
        zone_data = json.load(f)

    zone_name = zone_data["zone"]
    records = zone_data["records"]
    zone_dot = zone_name if zone_name.endswith(".") else zone_name + "."

    print(f"Loading zone: {zone_name} ({len(records)} records)")

    # Extract NS records for zone creation
    nameservers = []
    for r in records:
        if r["type"] == "NS":
            ns = r["content"]
            if not ns.endswith("."):
                ns += "."
            nameservers.append(ns)

    # Create zone if needed
    ensure_zone(zone_dot, nameservers)

    # Patch all records
    rrsets = build_rrsets(zone_dot, records)
    print(f"  Patching {len(rrsets['rrsets'])} rrsets...")
    api_request(f"/zones/{zone_dot}", method="PATCH", data=rrsets)
    print(f"  Done — zone {zone_name} loaded successfully")


if __name__ == "__main__":
    main()

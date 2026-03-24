#!/usr/bin/env python3
"""
Bringup guide generator.

Reads site/config.yaml and platform-specific Jinja2 templates to produce
site/bringup.md — a site-specific, step-by-step checklist for setting up
the physical infrastructure.
"""

import sys
import os
import re
import ipaddress
from datetime import datetime, timezone
from pathlib import Path

import yaml
from jinja2 import Environment, FileSystemLoader, TemplateNotFound, UndefinedError


def subnet_ip(cidr, offset):
    """Given a CIDR subnet and an offset, return the IP at that offset."""
    net = ipaddress.ip_network(cidr, strict=False)
    return str(net.network_address + offset)


def cidr_netmask(cidr):
    """Extract the netmask from CIDR notation."""
    net = ipaddress.ip_network(cidr, strict=False)
    return str(net.netmask)


def cidr_prefix(cidr):
    """Extract the prefix length from CIDR notation."""
    net = ipaddress.ip_network(cidr, strict=False)
    return net.prefixlen


def ip_strip_prefix(addr):
    """Strip the /prefix from an address like 10.10.2.1/30 → 10.10.2.1."""
    return addr.split("/")[0] if "/" in addr else addr


def main():
    if len(sys.argv) < 2:
        print("Usage: generate-bringup.py <config.yaml> [output.md]", file=sys.stderr)
        sys.exit(2)

    config_path = Path(sys.argv[1])
    if not config_path.exists():
        print(f"ERROR: Config file not found: {config_path}", file=sys.stderr)
        sys.exit(2)

    # Determine output path
    if len(sys.argv) >= 3:
        output_path = Path(sys.argv[2])
    else:
        output_path = config_path.parent / "bringup.md"

    # Load config
    with open(config_path) as f:
        config = yaml.safe_load(f)

    # Validate required fields
    required = ["domain", "environments", "management", "nodes", "nas",
                "proxmox", "vms", "public_ip", "platforms"]
    missing = [k for k in required if k not in config or config[k] is None]
    if missing:
        print(f"ERROR: Missing required config fields: {', '.join(missing)}", file=sys.stderr)
        sys.exit(2)

    # Validate MAC addresses
    for vm_name, vm_cfg in config.get("vms", {}).items():
        mac = vm_cfg.get("mac", "")
        if not mac or not mac.startswith("02:"):
            print(f"WARNING: VM '{vm_name}' MAC '{mac}' may be a placeholder "
                  f"(expected 02:xx:xx:xx:xx:xx)", file=sys.stderr)

    # Determine template directory
    script_dir = Path(__file__).resolve().parent
    template_dir = script_dir / "templates"

    # Set up Jinja2
    env = Environment(
        loader=FileSystemLoader(str(template_dir)),
        undefined=jinja2_strict_undefined(),
        keep_trailing_newline=True,
    )
    env.filters["subnet_ip"] = subnet_ip
    env.filters["cidr_netmask"] = cidr_netmask
    env.filters["cidr_prefix"] = cidr_prefix
    env.filters["ip_strip_prefix"] = ip_strip_prefix

    # Build template context
    has_replication_network = any(
        node.get("repl_peers") for node in config.get("nodes", [])
    )
    has_zones = 'zones' in config and config.get('zones') is not None

    cluster_config = config.get('cluster', {})
    cluster_name_setting = cluster_config.get('name', 'AUTO')
    if cluster_name_setting == 'AUTO':
        cluster_name = config['domain'].split('.')[0].lower()
        cluster_name = re.sub(r'[^a-z0-9-]', '-', cluster_name).strip('-')
    else:
        cluster_name = cluster_name_setting

    # Inject derived domain fields so templates can use e.g. {{ environments.prod.dns_domain }}
    domain = config["domain"]
    for env_name, env_cfg in config.get("environments", {}).items():
        env_cfg["dns_domain"] = f"{env_name}.{domain}"
    if "email" in config:
        config["email"].setdefault("from", f"gatus@{domain}")
    if "cicd" in config:
        config["cicd"].setdefault("gitlab_url", f"https://gitlab.prod.{domain}")

    context = {
        **config,
        "generation_timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "has_replication_network": has_replication_network,
        "has_zones": has_zones,
        "cluster_name": cluster_name,
        "gitlab_url": f"https://gitlab.prod.{domain}",
    }

    # Determine which platform templates to use
    gateway_type = config["platforms"]["gateway"]["type"]
    nas_type = config["platforms"]["nas"]["type"]
    registrar_type = config["platforms"]["registrar"]["type"]

    # Template rendering order
    sections = [
        ("common/header.md.j2", "Header", True),
        ("common/pre-flight.md.j2", "Pre-flight", True),
        ("proxmox/proxmox.md.j2", "Proxmox", False),
        (f"gateway/{gateway_type}.md.j2", f"Gateway: {gateway_type}", False),
        (f"registrar/{registrar_type}.md.j2", f"Registrar: {registrar_type}", False),
        (f"nas/{nas_type}.md.j2", f"NAS: {nas_type}", False),
        ("common/repo-bootstrap.md.j2", "Repo bootstrap", True),
        ("common/nix-builder.md.j2", "Nix builder", True),
        ("pbs/pbs-setup.md.j2", "PBS setup", False),
        ("gitlab/gitlab-setup.md.j2", "GitLab and CI/CD", False),
        ("monitoring/monitoring-setup.md.j2", "Monitoring", False),
        ("common/validation.md.j2", "Validation", True),
    ]

    rendered_parts = []
    templates_used = []

    for template_path, section_name, is_required in sections:
        try:
            tmpl = env.get_template(template_path)
            rendered = tmpl.render(**context)
            rendered_parts.append(rendered)
            templates_used.append(f"  ✓ {template_path}")
        except TemplateNotFound:
            if is_required:
                print(f"ERROR: Required template not found: {template_path}", file=sys.stderr)
                sys.exit(2)
            # Generate placeholder for missing platform template
            placeholder = generate_placeholder(section_name, template_path)
            rendered_parts.append(placeholder)
            templates_used.append(f"  ⊘ {template_path} (missing — placeholder inserted)")
        except UndefinedError as e:
            print(f"ERROR: Undefined variable in {template_path}: {e}", file=sys.stderr)
            sys.exit(2)

    # Assemble output
    header_comment = (
        "<!-- Generated by framework/bringup/generate-bringup.py — DO NOT EDIT MANUALLY -->\n"
        "<!-- This file is site-specific and must not be published to the public remote. -->\n"
        "<!-- Regenerate with: framework/bringup/generate-bringup.sh -->\n\n"
    )
    output = header_comment
    output += "\n\n".join(part.rstrip() for part in rendered_parts if part.strip())
    output += "\n"

    # Write output
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        f.write(output)

    # Report
    print(f"Generated: {output_path}")
    print(f"Templates used:")
    for t in templates_used:
        print(t)


def generate_placeholder(section_name, template_path):
    """Generate a placeholder section for a missing platform template."""
    platform_type = template_path.split("/")[-1].replace(".md.j2", "")
    category = template_path.split("/")[0]
    return (
        f"## {section_name} — Template not yet available\n\n"
        f"No template found at `{template_path}`.\n"
        f"Refer to `implementation-plan.md` Step 0 for generic {category} instructions.\n\n"
        f"To contribute a template for **{platform_type}**, create "
        f"`framework/bringup/templates/{template_path}` following the existing templates as examples."
    )


def jinja2_strict_undefined():
    """Return Jinja2's StrictUndefined class for better error messages."""
    from jinja2 import StrictUndefined
    return StrictUndefined


if __name__ == "__main__":
    main()

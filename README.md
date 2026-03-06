# homelab

Automation scripts and operational helpers for a personal homelab.

This repository is for practical tooling used to manage:
- TrueNAS storage operations and migrations
- Proxmox host and VM/container workflows
- Linux administration tasks
- Networking setup and validation
- Repeatable configuration and maintenance automations

## Goals
- Keep repetitive homelab tasks scriptable and consistent.
- Prefer safe defaults and explicit guardrails for destructive actions.
- Make scripts readable, auditable, and easy to run in batches.

## Repository Usage
- Add scripts as focused, single-purpose tools.
- Include clear inline usage comments at the top of each script.
- Use environment variables for runtime options when possible.
- Default to dry-run or non-destructive behavior when feasible.

## Current Scripts
- `bulk_file_migrate.sh`: Incremental, verify-before-delete folder migration helper for large dataset moves.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Pluto is the public edge for the homelab: an OVH VPS (Debian 13) that answers
for `*.pwbcloud.com`, filters traffic with CrowdSec, and proxies it to Caddy
on Jupiter over the tailnet. `README.md` has the picture and the setup steps,
`docs/RUNBOOK.md` the operations. Jupiter (`Sunstead/Jupiter`) and Cosmos
(`Sunstead/Cosmos`) are usually checked out beside this repo.

- `docker-compose.yml` only `include`s `compose/*.yml`: `edge.yml` (Caddy,
  CrowdSec) and `cosmos.yml` (the Cosmos agent).
- `caddy/Caddyfile` has one site per public name, each `import edge` +
  `import to_jupiter <name>`. Caddy is built here (`caddy/Dockerfile`) with
  CrowdSec's `http` and `appsec` modules.
- `host/` is the machine's own config (nftables, sshd, sysctl, Docker, apt),
  installed by `scripts/bootstrap.sh`. `scripts/deploy.sh` deploys the stack.
- `docs/tailnet-policy.hujson` mirrors the live tailnet policy in the
  Tailscale admin console. It's the reason a compromised Pluto can only reach
  `jupiter:443`.

## Security model (don't weaken it by accident)

- **Nothing listens publicly except Caddy (80/443) and tailscaled (41641/udp).**
  Caddy and the agent use host networking; CrowdSec's ports are published on
  127.0.0.1 only; the agent binds 127.0.0.1:7700 and the tailnet reaches it
  through `tailscale serve`. A new port is a change to `host/nftables.conf`
  and the README.
- **`host/nftables.conf` must never `flush ruleset`.** Docker and Tailscale
  keep their own tables; it replaces only `table inet pluto`.
- **Pluto holds no DNS credentials and no GitHub token.** Certificates come
  from HTTP/TLS-ALPN challenges; deploys are `scripts/deploy.sh` by hand. Keep
  it that way.
- **The tailnet policy is the containment.** Pluto (`tag:pluto`) may reach
  `jupiter:443` and nothing else. Anything new that needs more access is a
  policy change in both places, with its `tests` updated.
- Pluto terminates TLS and sees plaintext. Upstream connections to Jupiter
  are TLS too, verified against Jupiter's real certificate via a literal
  `tls_server_name` per site (a placeholder would clone the transport per
  request and lose pooling).

## Conventions

- **Secrets live only in Pluto's `.env`.** Add every new variable to
  `.env.example` with a placeholder and a comment. Nothing secret in git.
- **Images are pinned to explicit tags.** Caddy's version and the bouncer
  module's are build args in `caddy/Dockerfile`. The Cosmos agent is pinned
  to the same release as Jupiter's and bumped with `cosmos-agent.toml` in the
  same commit; an agent refuses a config it doesn't understand
  (`cosmos-agent --check-config <file>` from the Cosmos repo checks one).
- **Every service carries a `cosmos.service` label** (`system` for
  infrastructure), as on Jupiter.
- **Large uploads must keep working.** No request body limits or timeouts in
  Caddy; `appsec_max_body_bytes` stays a small cap (0 means AppSec buffers
  the whole body).
- **CrowdSec false positives** go in `crowdsec/parsers/s02-enrich/pluto-whitelist.yaml`
  (narrowest expression that fits) or `crowdsec/simulation.yaml` (a whole
  scenario that only alerts). Don't remove hub items: that taints their
  collection and stops its upgrades.
- Bind-mounted config is read at startup; `deploy.sh` restarts a service
  whose file is newer than its container. A new bind-mounted file needs
  adding to its `restart_if_newer` line.
- **This repository is public** (`Sunstead/Pluto`). Nothing in it may be
  secret, and it shouldn't say more about the setup than DNS and the tailnet
  policy already do.
- Never run commands against the server without explicit confirmation. Write
  the steps up first.
- Shell scripts: `set -euo pipefail`, and every step is safe to re-run.

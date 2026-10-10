# Pluto

The public edge for the homelab. A small OVH VPS (Debian 13) that answers for
`*.pwbcloud.com`, filters what comes in, and forwards the rest to Jupiter over
the tailnet. It also runs ntfy, so notifications reach the phone even when
Jupiter can't. The home connection never appears in DNS and has no open ports.
Everything here can be rebuilt from this repository.

| Public name | App on Jupiter |
| --- | --- |
| `auth.pwbcloud.com` | Authentik, the sign-in for the rest (admin UI blocked; it stays on the tailnet) |
| `photos.pwbcloud.com` | Immich |
| `files.pwbcloud.com` | OpenCloud |
| `git.pwbcloud.com` | Gitea (HTTPS only) |
| `atlas.pwbcloud.com` | Atlas |
| `notes.pwbcloud.com` | Solstice: the web app and the desktop apps' sync |

| Public name | Served here |
| --- | --- |
| `ntfy.pwbcloud.com` | ntfy, push notifications from both Cosmos agents to the phone |

Cosmos is not public; it stays on `*.jupiter.sunstead.net`, tailnet only.

**Why ntfy is here, not on Jupiter:** a notification that Jupiter is down
(or that the house lost power) needs a server that isn't Jupiter, and the
phone shouldn't need the tailnet to read one. Both agents publish here:
Pluto's on loopback, Jupiter's over the internet like any visitor. The only
thing that can't come through here is "Pluto is down"; Jupiter sends that one
to ntfy.sh (Jupiter's `docs/NOTIFICATIONS.md`).

## How a request gets in

```
internet ──► Pluto :80/:443   nftables: 80, 443/tcp and 41641/udp, nothing else
             Caddy            TLS for the public name (its own Let's Encrypt cert)
               ├─ CrowdSec    banned address? → 403. AppSec rule matches? → 403.
               ├─ proxy ──────► tailnet (Pluto may reach jupiter:443 and nothing else)
               │                 └─► Jupiter's Caddy (*.pwbcloud.com, its own cert) ─► app
               └─ ntfy.pwbcloud.com ─► ntfy on 127.0.0.1:2586 (this machine)

your devices ──► tailnet ──► pluto:22                     SSH, keys only
                         └─► https://pluto.<tailnet>.ts.net:7700   Cosmos agent (tailscale serve)
```

- **TLS ends here**, so CrowdSec can read the requests. Caddy then opens a
  new TLS connection to Jupiter inside the tunnel and checks Jupiter's real
  certificate. Pluto does see your traffic in plaintext, which is why it's
  locked down this far.
- **No DNS credentials on Pluto.** Its certificates come from HTTP/TLS-ALPN
  challenges. Only Jupiter holds the Cloudflare token.
- **Jupiter serves the same names** with its own wildcard certificate. Apps
  there reach Authentik and themselves locally, without going round through
  Pluto, and the names would keep working if DNS at home ever pointed at
  Jupiter directly.
- **CrowdSec** blocks addresses on its community blocklist, bans ones its
  scenarios catch in Caddy's logs (scanners, CVE probes, brute force), and
  checks every request against AppSec's virtual patches before it's proxied.
- **The tailnet policy** ([docs/tailnet-policy.hujson](docs/tailnet-policy.hujson))
  only lets `tag:pluto` reach `jupiter:443`. If Pluto is ever compromised, it
  can't reach your other devices.

## Layout

- `docker-compose.yml` includes `compose/*.yml`: `edge.yml` (Caddy, CrowdSec),
  `cosmos.yml` (the Cosmos agent) and `notify.yml` (ntfy).
- `caddy/`: the Caddyfile and the Dockerfile that builds Caddy with CrowdSec's
  modules.
- `crowdsec/`: what CrowdSec reads, its whitelist and the scenarios that
  only alert.
- `cosmos-agent.toml`: the agent's config.
- `host/`: firewall, SSH, sysctl, Docker and unattended-upgrade config, which
  `scripts/bootstrap.sh` installs.
- `scripts/bootstrap.sh` (once per machine), `scripts/deploy.sh` (every change).
- `docs/RUNBOOK.md`: DNS, CrowdSec, recovery.

## Building Pluto from scratch

1. **OVH:** a VPS with the Debian 13 image and your SSH key. Check its IPv4
   on [AbuseIPDB](https://www.abuseipdb.com/) and
   [Spamhaus](https://check.spamhaus.org/); if it's listed, ask OVH for another
   before any DNS points at it.
2. **Tailscale admin console:**
   - Access controls: paste [docs/tailnet-policy.hujson](docs/tailnet-policy.hujson)
     with Jupiter's IP filled in. Its tests have to pass.
   - DNS: MagicDNS and HTTPS certificates on (for the agent's
     `pluto.<tailnet>.ts.net`). Machine names on the tailnet show up in public
     certificate logs once this is on.
   - Settings > Keys: a pre-approved, single-use auth key with tag `tag:pluto`.
3. **On Pluto**, over the public SSH it has at first:
   ```bash
   sudo apt-get update && sudo apt-get install -y git
   sudo install -d -o "$USER" -g "$USER" /opt/pluto
   git clone https://github.com/Sunstead/Pluto.git /opt/pluto
   cd /opt/pluto
   sudo scripts/bootstrap.sh
   ```
   (`sudo scripts/bootstrap.sh --prepare` first does everything that needs
   no input, if someone else is getting the machine ready.) It asks for the auth key and a console password, and finally has you
   confirm the firewall from a second SSH session over the tailnet
   (`ssh -t <you>@pluto sudo touch /run/pluto-firewall-ok`). Public SSH is
   closed from then on. Check `tailscale ping jupiter` reports a direct
   connection, not DERP.
4. **Log in again over the tailnet** (`ssh <you>@pluto`) for the docker group, then:
   ```bash
   cd /opt/pluto
   cp .env.example .env    # fill it in; the comments say how
   scripts/deploy.sh
   ```
5. **DNS** at Cloudflare: the records in [docs/RUNBOOK.md](docs/RUNBOOK.md#dns).
   Caddy gets each certificate as soon as its name resolves here.
6. **Cosmos:** Add node `https://pluto.<tailnet>.ts.net:7700`. On Pluto's node, add
   HTTP uptime checks for the public names, and an ntfy channel: server
   `http://127.0.0.1:2586`, topic `cosmos-pluto`, token `NTFY_PLUTO_TOKEN`.
   Jupiter's channel uses `https://ntfy.pwbcloud.com`, topic `cosmos-jupiter`,
   token `NTFY_JUPITER_TOKEN`.
7. **Phone:** in the ntfy app, add the user `phone` on server
   `https://ntfy.pwbcloud.com`, and subscribe to `cosmos-jupiter` and
   `cosmos-pluto` there.

Rebuilding means doing the same again. Nothing on the old machine needs
saving: certificates are re-issued, CrowdSec re-learns, and ntfy's accounts
come from `.env` (its cache only holds messages already delivered). Remove the old
`pluto` from the tailnet first, and update the DNS records if the IP
changed.

## Changing things

Edit here, commit, push, then on Pluto: `scripts/deploy.sh`. It pulls,
rebuilds Caddy if its Dockerfile changed, recreates what changed and restarts
anything whose config file did. Host config under `host/` takes a re-run of
`sudo scripts/bootstrap.sh`.

# Runbook

Commands run on Pluto from `/opt/pluto` unless they say otherwise.

## DNS

`pwbcloud.com` is on Cloudflare. Every record is **DNS only** (grey cloud):
Cloudflare's proxy would end TLS before Pluto and cap uploads at 100 MB.

| Type | Name | Value |
| --- | --- | --- |
| A | `auth`, `photos`, `files`, `git`, `atlas` | Pluto's IPv4 |
| AAAA | the same five | Pluto's IPv6, once `curl -6 https://photos.pwbcloud.com` works from a v6 network |
| CAA | `@` | `0 issue "letsencrypt.org"` |
| CAA | `@` | `0 issuewild "letsencrypt.org"` (Jupiter's wildcard) |

No wildcard record: a name only resolves once it's meant to be public.
Jupiter's own `*.pwbcloud.com` certificate comes from a DNS-01 challenge with
its Cloudflare token, which needs **Zone > DNS > Edit** on `pwbcloud.com` too.

A new public site: the record here, a block in `caddy/Caddyfile`, and a route
in Jupiter's `*.pwbcloud.com` site.

## CrowdSec

`cscli` runs inside the container:

```bash
docker compose exec crowdsec cscli metrics            # is Caddy's log being parsed?
docker compose exec crowdsec cscli alerts list        # what tripped, and on what
docker compose exec crowdsec cscli decisions list     # who's banned now (local)
docker compose exec crowdsec cscli bouncers list      # Caddy's bouncer, last pull
```

**Unban someone** (yourself, after a false positive):

```bash
docker compose exec crowdsec cscli decisions delete --ip 203.0.113.7
```

Then make it not happen again. `cscli alerts inspect -d <id>` shows the
requests behind an alert. If they're normal app traffic, add the narrowest
expression that matches them to
`crowdsec/parsers/s02-enrich/pluto-whitelist.yaml`. If a whole scenario
doesn't fit these apps, list it in `crowdsec/simulation.yaml` (alerts, no
bans). Commit, deploy.

**AppSec blocked a real request:** `cscli alerts list` shows an
`crowdsecurity/appsec-*` or `vpatch-*` alert. Excluding a rule is a
`crowdsec/appsec-configs` override; write it up with the alert before changing
anything.

**Test a ban end to end:**

```bash
docker compose exec crowdsec cscli decisions add --ip <your phone's IP> --duration 5m
# the phone (off Wi-Fi) now gets 403 from every site within ~15 s
docker compose exec crowdsec cscli decisions delete --ip <your phone's IP>
```

**Rotate the bouncer key:** put a new `CROWDSEC_BOUNCER_KEY` in `.env`, then

```bash
docker compose exec crowdsec cscli bouncers delete caddy
docker compose up -d --force-recreate crowdsec caddy
```

CrowdSec registers the bouncer again with the new key when it starts.

If CrowdSec is down, Caddy fails closed: AppSec can't answer, so requests
get an error instead of passing unchecked. `docker compose ps` and
`docker compose logs crowdsec` first.

## Is the tunnel healthy?

```bash
tailscale status
tailscale ping jupiter             # "via <ip>:<port>" is direct; "via DERP" is a slow relay
curl -sI --resolve photos.pwbcloud.com:443:$(sed -n 's/^JUPITER_TS_IP=//p' .env) https://photos.pwbcloud.com
```

The last one goes straight to Jupiter's Caddy, skipping Pluto's. If it works
but the public name doesn't, the problem is on Pluto.

Pluto shouldn't be able to reach anything else on Jupiter. This should time out:
`curl -m 5 http://$(sed -n 's/^JUPITER_TS_IP=//p' .env):7700/healthz`

## Can't get in

- **SSH over the tailnet fails:** the OVH control panel's KVM console logs in
  with the password bootstrap.sh had you set. Then `sudo tailscale status`,
  `sudo systemctl status tailscaled ssh`.
- **No console password, or the system won't boot:** OVH rescue mode, mount
  the disk, fix it from there. Or rebuild (README.md); nothing on Pluto is
  irreplaceable.
- **Locked yourself out with the firewall:** from the console,
  `sudo nft delete table inet pluto` opens everything again until the next
  boot or `sudo systemctl restart nftables`.

## Updates

Debian, Tailscale and Docker update themselves (`host/apt.conf.d`), with a
reboot at 04:30 when a kernel update needs one. Container images are pinned:
Cosmos shows newer tags on its Updates page, and they're bumped by hand here,
the Caddy build in `caddy/Dockerfile`. Then `scripts/deploy.sh`.

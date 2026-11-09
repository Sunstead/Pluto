# Runbook

Commands run on Pluto from `/opt/pluto` unless they say otherwise.

## DNS

`$PUBLIC_DOMAIN` is on Cloudflare. Every record is **DNS only** (grey cloud):
Cloudflare's proxy would end TLS before Pluto and cap uploads at 100 MB.

| Type | Name | Value |
| --- | --- | --- |
| A | `auth`, `photos`, `files`, `git`, `atlas`, `notes`, `lodestone`, `dav`, `play`, `ntfy` | Pluto's IPv4 |
| AAAA | the same ten | Pluto's IPv6, once `curl -6 https://photos.$PUBLIC_DOMAIN` works from a v6 network |
| CAA | `@` | `0 issue "letsencrypt.org"` |
| CAA | `@` | `0 issuewild "letsencrypt.org"` (Jupiter's wildcard) |

No wildcard record: a name only resolves once it's meant to be public.

`play` is the one name that isn't a website: Minecraft players connect to it on
the game ports (below). Grey cloud matters most there, since Cloudflare's proxy
only carries HTTP. It has no certificate and no site in `caddy/Caddyfile`.

Servers' address names (`survival.play.$PUBLIC_DOMAIN`) are SRV records that
Lodestone on Jupiter keeps in Cloudflare itself, tagged with a `lodestone:`
comment, all pointing at `play.$PUBLIC_DOMAIN` on a game port. Nothing to do
here for them; don't edit those records by hand.
Jupiter's own `*.$PUBLIC_DOMAIN` certificate comes from a DNS-01 challenge with
its Cloudflare token, which needs **Zone > DNS > Edit** on `$PUBLIC_DOMAIN` too.

A new public site: the record here, a block in `caddy/Caddyfile`, and a route
in Jupiter's `*.$PUBLIC_DOMAIN` site (except ntfy, which is served here).

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

An alert whose decision reads `(simul)ban` banned no one: its scenario is in
`crowdsec/simulation.yaml`. `cscli decisions list --ip <address>` says
whether an address is really banned; check it before touching the whitelist.

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
PUBLIC_DOMAIN=$(sed -n 's/^PUBLIC_DOMAIN=//p' .env)
tailscale status
tailscale ping jupiter             # "via <ip>:<port>" is direct; "via DERP" is a slow relay
curl -sI --resolve photos.$PUBLIC_DOMAIN:443:$(sed -n 's/^JUPITER_TS_IP=//p' .env) https://photos.$PUBLIC_DOMAIN
```

The last one goes straight to Jupiter's Caddy, skipping Pluto's. If it works
but the public name doesn't, the problem is on Pluto.

Pluto shouldn't be able to reach anything else on Jupiter but 443 and the
game ports. These should time out:
`curl -m 5 http://$(sed -n 's/^JUPITER_TS_IP=//p' .env):7700/healthz`,
`nc -zv -w 5 $(sed -n 's/^JUPITER_TS_IP=//p' .env) 25575` (the first RCON port).

## Game connections

`play.$PUBLIC_DOMAIN:<port>` reaches Lodestone's Minecraft servers on Jupiter.
`compose/game.yml` runs HAProxy (`game/haproxy.cfg`), which forwards each
port in `LODESTONE_GAME_PORTS` to the same port on Jupiter over the tailnet,
and nothing else. It limits each address to 8 open connections and 15 new
ones in 10 seconds, and logs every connection.

```bash
docker compose logs --tail 50 game                       # who connected, for how long
nc -zv $(sed -n 's/^JUPITER_TS_IP=//p' .env) 30000       # Jupiter's side, if a server uses it
```

- **The range** is in four places: `.env` here, `host/nftables.conf`, the
  tailnet policy, and `LODESTONE_GAME_PORTS` in Jupiter's `.env`. Change them
  together, then `scripts/deploy.sh` and `sudo scripts/bootstrap.sh` (for the
  firewall).
- **CrowdSec doesn't see this traffic.** Its bans cover the websites only.
  Block an address from the game ports by hand in `host/nftables.conf`, or
  ban the player by name on the server.
- **Servers see Pluto, not the player.** Every connection reaches a server
  from Jupiter's side of the tunnel, so bans by IP in Minecraft ban everyone.
  The real address is in this log. PROXY protocol would fix it, but only
  Paper understands it; vanilla and modded servers refuse every connection
  that has it, so it's off.
- **Players can't connect, the website works:** is the port in the range, and
  does `docker compose logs game` show the connection? `<NOSRV>` or a
  connection that ends at once means Jupiter refused it: the server isn't
  running, or the tailnet policy is missing the range.

Check from outside (another network, not the tailnet) that only these are
open:

```bash
nmap -Pn -p 1-65535 --open <Pluto's IPv4>     # 80, 443 and the game range
nmap -Pn -sU -p 30000,41641 <Pluto's IPv4>    # no query port
```

## Notifications (ntfy)

```bash
PUBLIC_DOMAIN=$(sed -n 's/^PUBLIC_DOMAIN=//p' .env)
docker compose ps ntfy                                   # healthy?
docker compose logs --tail 50 ntfy
curl -s https://ntfy.$PUBLIC_DOMAIN/v1/health            # through Caddy and CrowdSec
```

- **Send test** on a channel in Helion (Settings > Notifications) reports the
  error at once: `HTTP 403` is the token or the ACL, `couldn't connect` the
  address.
- **The phone stops getting them:** a wrong password in the ntfy app gets 401s,
  and enough of those look like brute force to CrowdSec. Check
  `cscli decisions list` for the phone's address before anything else.
- **Rotating a secret:** change it in `.env` and `scripts/deploy.sh` (or
  `docker compose up -d --force-recreate ntfy`); ntfy re-applies the accounts
  on start. Then update the token in that node's Helion channel.

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
Helion shows newer tags on its Updates page, and they're bumped by hand here,
the Caddy build in `caddy/Dockerfile`. Then `scripts/deploy.sh`.

#!/bin/bash
# Turns a fresh Debian 13 VPS into Pluto. Run once from the checkout, as your
# own account through sudo:
#   sudo scripts/bootstrap.sh
# Safe to re-run: each step checks before it changes anything.
#
# In order: packages (Docker and Tailscale from their own repositories,
# unattended upgrades), the host config in host/, SSH, a console password,
# joining the tailnet, the Cosmos agent's tailnet address, and last the
# firewall, which takes itself back out unless you confirm you can still get
# in over the tailnet. README.md has the steps around it.
#
#   sudo scripts/bootstrap.sh --prepare
# stops before the console password: everything up to there needs no input,
# so the machine can be got ready ahead of time without anyone's secrets.
set -euo pipefail

prepare_only=
case "${1:-}" in
  --prepare) prepare_only=1 ;;
  "") ;;
  *) echo "usage: $0 [--prepare]" >&2; exit 2 ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/.."

die() { echo "bootstrap: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0"
ADMIN_USER="${SUDO_USER:-}"
[ -n "$ADMIN_USER" ] && [ "$ADMIN_USER" != root ] \
  || die "run through sudo from your own account, so SSH keeps working for it"

# shellcheck source=/dev/null
. /etc/os-release
[ "${VERSION_CODENAME:-}" = trixie ] || die "expected Debian 13 (trixie), found ${PRETTY_NAME:-unknown}"

# No prompts: keep any config file the image already changed (dpkg would
# otherwise stop and ask), and let needrestart restart services itself.
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt_get() { apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"; }

# install_if_changed <src> <dest> [mode]: prints "changed" when it wrote the file.
install_if_changed() {
  local src="$1" dest="$2" mode="${3:-0644}"
  if ! cmp -s "$src" "$dest"; then
    install -D -m "$mode" "$src" "$dest"
    echo changed
  fi
}

step "Packages"
apt_get update
apt_get -y full-upgrade
apt_get install -y ca-certificates curl git jq nftables unattended-upgrades apt-listchanges needrestart

install -d -m 0755 /etc/apt/keyrings
if [ ! -f /etc/apt/sources.list.d/docker.sources ]; then
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $VERSION_CODENAME
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
fi
if [ ! -f /etc/apt/sources.list.d/tailscale.list ]; then
  curl -fsSL "https://pkgs.tailscale.com/stable/debian/$VERSION_CODENAME.noarmor.gpg" \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL "https://pkgs.tailscale.com/stable/debian/$VERSION_CODENAME.tailscale-keyring.list" \
    -o /etc/apt/sources.list.d/tailscale.list
fi
apt_get update
apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin tailscale

step "Host configuration"
install_if_changed host/sysctl.d/90-pluto.conf /etc/sysctl.d/90-pluto.conf >/dev/null
sysctl --quiet --system
install_if_changed host/apt.conf.d/52pluto-unattended /etc/apt/apt.conf.d/52pluto-unattended >/dev/null
install_if_changed host/needrestart/pluto.conf /etc/needrestart/conf.d/pluto.conf >/dev/null
if [ -n "$(install_if_changed host/nftables.service.d/pluto.conf /etc/systemd/system/nftables.service.d/pluto.conf)" ]; then
  systemctl daemon-reload
fi
if [ -n "$(install_if_changed host/docker/daemon.json /etc/docker/daemon.json)" ]; then
  systemctl restart docker
fi
systemctl enable --now docker
# deploy.sh runs as you. Docker access is root-equivalent; so is sudo.
usermod -aG docker "$ADMIN_USER"

step "SSH: keys only, admins only"
home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
[ -s "$home/.ssh/authorized_keys" ] \
  || die "$ADMIN_USER has no ~/.ssh/authorized_keys; keys-only SSH would lock you out"
# AllowGroups sudo (host/sshd_config.d/10-pluto.conf).
id -nG "$ADMIN_USER" | grep -qw sudo || usermod -aG sudo "$ADMIN_USER"
install_if_changed host/sshd_config.d/10-pluto.conf /etc/ssh/sshd_config.d/10-pluto.conf >/dev/null
sshd -t
systemctl reload ssh

if [ -n "$prepare_only" ]; then
  echo
  echo "Prepared. The rest needs you: sudo scripts/bootstrap.sh"
  [ ! -e /run/reboot-required ] || echo "The upgrade wants a reboot first (sudo reboot)."
  exit 0
fi

step "Console password"
# Cloud images lock the account's password. SSH never accepts one; this is
# for the OVH KVM console, the way back in if the tailnet is ever down.
if [ "$(passwd -S "$ADMIN_USER" | awk '{print $2}')" != P ]; then
  echo "Set a password for $ADMIN_USER and keep it in your password manager."
  passwd "$ADMIN_USER"
else
  echo "$ADMIN_USER already has one"
fi

step "Tailscale"
systemctl enable --now tailscaled
if tailscale status >/dev/null 2>&1; then
  echo "Already on the tailnet as $(tailscale status --json | jq -r '.Self.DNSName')"
else
  echo "Paste a pre-approved, single-use auth key tagged tag:pluto"
  echo "(Tailscale admin > Settings > Keys; the tag needs docs/tailnet-policy.hujson in place)."
  read -r -s -p "Auth key: " authkey
  echo
  # Through a file, so the key never shows up in `ps`.
  keyfile="$(mktemp)"
  trap 'rm -f "$keyfile"' EXIT
  printf '%s' "$authkey" > "$keyfile"
  tailscale up --auth-key="file:$keyfile" --hostname=pluto \
    --advertise-tags=tag:pluto --accept-dns=false
  rm -f "$keyfile"
fi
tailnet_name="$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')"

step "Cosmos agent on the tailnet"
# HTTPS on the tailnet name, answered inside tailscaled, proxied to the agent
# on loopback (cosmos-agent.toml). Needs MagicDNS and HTTPS certificates
# turned on in the Tailscale admin console (DNS page).
if tailscale serve status 2>/dev/null | grep -q '127.0.0.1:7700'; then
  echo "Already serving https://$tailnet_name"
else
  tailscale serve --bg --https=443 http://127.0.0.1:7700
fi

step "Firewall"
nft -c -f host/nftables.conf
if cmp -s host/nftables.conf /etc/nftables.conf && nft list table inet pluto >/dev/null 2>&1; then
  echo "Already in place"
else
  nft -f host/nftables.conf
  rm -f /run/pluto-firewall-ok
  cat <<EOF
Applied. Public SSH is closed now; this session stays up.
Within 2 minutes, from your own machine on the tailnet, run:

  ssh -t $ADMIN_USER@pluto sudo touch /run/pluto-firewall-ok

If that doesn't arrive, the firewall is taken back out.
EOF
  for _ in $(seq 120); do
    [ -e /run/pluto-firewall-ok ] && break
    sleep 1
  done
  if [ ! -e /run/pluto-firewall-ok ]; then
    nft delete table inet pluto
    die "not confirmed, so the firewall is off again. Check 'tailscale status' here and SSH to pluto over the tailnet, then re-run"
  fi
  # Keep Debian's stock file once, for reference. It starts with
  # `flush ruleset`, which is why it's replaced, not added to.
  [ -f /etc/nftables.conf.debian ] || cp /etc/nftables.conf /etc/nftables.conf.debian
  install -m 0755 host/nftables.conf /etc/nftables.conf
  systemctl enable nftables
  echo "Confirmed; loaded at every boot from now on"
fi

cat <<EOF

Done. Next (README.md):
  1. cp .env.example .env and fill it in
  2. scripts/deploy.sh            (as $ADMIN_USER, after logging in again for the docker group)
  3. Add https://$tailnet_name in Cosmos
EOF
if [ -e /run/reboot-required ]; then
  echo "The upgrade wants a reboot (sudo reboot); everything above comes back on its own."
fi

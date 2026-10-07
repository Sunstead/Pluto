#!/bin/bash
# Deploys main to this server. Run on Pluto, from the checkout, as the admin
# account (in the docker group since bootstrap.sh):
#   scripts/deploy.sh
#
# The same steps as Jupiter's deploy workflow (.github/workflows/_deploy.yml
# there), by hand: Pluto runs no CI runner, so the internet-facing box holds
# no GitHub credential beyond this repository's read-only deploy key.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

die() { echo "deploy: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

[ -f .env ] || die ".env is missing: cp .env.example .env and fill it in"

step "Update checkout"
if git remote get-url origin >/dev/null 2>&1; then
  git pull --ff-only origin main
else
  echo "No origin remote; deploying the checkout as it is"
fi

step "Validate compose files"
docker compose config -q

step "Build and pull images"
docker compose build --pull
for attempt in 1 2 3; do
  docker compose pull --ignore-buildable && break
  [ "$attempt" -lt 3 ] || die "pull failed three times"
  echo "Pull failed (attempt $attempt), retrying in 15s..."
  sleep 15
done

# With the new image, before anything running is touched: a broken Caddyfile
# stops the deploy here instead of taking every site down.
step "Validate Caddyfile"
docker compose run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

step "Apply changes"
docker compose up -d --remove-orphans

# `up -d` only recreates a container when its compose definition changes, so
# an edit to a bind-mounted config file alone never reaches it: Caddy, the
# agent and CrowdSec read theirs at startup. git stamps changed files with the
# time of the pull, so anything whose config is newer than the container gets
# restarted.
step "Restart services whose config changed"
restart_if_newer() {
  local service="$1" id started changed file
  shift
  id="$(docker compose ps -q "$service")"
  [ -n "$id" ] || return 0
  started="$(date -d "$(docker inspect -f '{{.State.StartedAt}}' "$id")" +%s)"
  for file in "$@"; do
    changed="$(stat -c %Y "$file")"
    if [ "$changed" -gt "$started" ]; then
      echo "$file changed after $service started; restarting it"
      docker compose restart "$service"
      return 0
    fi
  done
}
restart_if_newer caddy ./caddy/Caddyfile
restart_if_newer cosmos-agent ./cosmos-agent.toml
restart_if_newer crowdsec ./crowdsec/acquis.d/*.yaml ./crowdsec/parsers/s02-enrich/*.yaml ./crowdsec/simulation.yaml

step "Prune old images"
docker image prune -f

step "Status"
docker compose ps

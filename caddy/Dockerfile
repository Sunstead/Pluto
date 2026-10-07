# Caddy with CrowdSec's bouncer: `http` blocks addresses CrowdSec has
# decided against, `appsec` checks each request against its AppSec rules.
# Built on Pluto by scripts/deploy.sh. Bump both versions by hand; Cosmos
# can't see a locally built image.
ARG CADDY_VERSION=2.11.7

FROM caddy:${CADDY_VERSION}-builder AS builder
ARG CROWDSEC_BOUNCER_VERSION=v0.14.1
RUN xcaddy build \
    --with github.com/hslatman/caddy-crowdsec-bouncer/http@${CROWDSEC_BOUNCER_VERSION} \
    --with github.com/hslatman/caddy-crowdsec-bouncer/appsec@${CROWDSEC_BOUNCER_VERSION}

FROM caddy:${CADDY_VERSION}
COPY --from=builder /usr/bin/caddy /usr/bin/caddy

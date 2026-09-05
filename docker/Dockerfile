# agent-fleet default hardened image (#12) — the container rung's fallback
# when a repo ships no devcontainer. Modeled on Anthropic's reference
# devcontainer: Claude Code + a default-deny egress firewall (init-firewall.sh
# documents the allowlist). Built on first use: docker build -t af-default .
FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates curl bash procps \
      iptables ipset dnsutils util-linux \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY entrypoint.sh    /usr/local/bin/af-entrypoint.sh
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/af-entrypoint.sh

# Root at start: the firewall needs NET_ADMIN + iptables; the entrypoint drops
# to AF_UID/AF_GID (the host user) before exec'ing the agent, so files written
# into the mounted worktree keep sane ownership.
ENTRYPOINT ["/usr/local/bin/af-entrypoint.sh"]

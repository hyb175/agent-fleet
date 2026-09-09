#!/usr/bin/env bash
# init-firewall.sh — default-deny egress for the af-default image.
#
# THE ALLOWLIST (documented contract — the container can reach ONLY these):
#   api.anthropic.com console.anthropic.com statsig.anthropic.com
#   api.statsig.com                                                Claude API
#   sentry.io                                                      crash relay
#   registry.npmjs.org                                             npm installs
#   github.com api.github.com codeload.github.com                  git + gh
#   objects.githubusercontent.com raw.githubusercontent.com        release blobs
# Plus: loopback, established/related inbound replies, and DNS (53) to the
# container's configured resolvers — name resolution is how the allowlist
# itself is built. IPv6 egress is dropped wholesale.
#
# Runs as root at container start (needs --cap-add NET_ADMIN). set -e on
# purpose: a firewall that half-applies must FAIL the entrypoint (which then
# refuses to start the agent) — failing open here is the container-rung
# equivalent of running unsandboxed under a record that claims otherwise.
# Only per-host resolution failures are tolerated (noted and skipped).
set -euo pipefail

ALLOWED_DOMAINS=(
  api.anthropic.com console.anthropic.com statsig.anthropic.com api.statsig.com
  sentry.io
  registry.npmjs.org
  github.com api.github.com codeload.github.com
  objects.githubusercontent.com raw.githubusercontent.com
)

iptables -F OUTPUT
ipset destroy af-allowed 2>/dev/null || true
ipset create af-allowed hash:ip

for d in "${ALLOWED_DOMAINS[@]}"; do
  ips="$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  if [[ -z "$ips" ]]; then
    echo "af-firewall: could not resolve $d (skipped)" >&2
    continue
  fi
  while IFS= read -r ip; do
    ipset add af-allowed "$ip" 2>/dev/null || true
  done <<< "$ips"
done

iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# DNS to the CONFIGURED resolvers only — an unrestricted :53 rule would be a
# general egress tunnel to anything listening on port 53.
dns_v4=""
dns_v4="$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null || true)"
if [[ -n "$dns_v4" ]]; then
  while IFS= read -r ns; do
    [[ -z "$ns" || "$ns" == *:* ]] && continue   # skip blanks + v6 resolvers
    iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
  done <<< "$dns_v4"
else
  iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
fi
iptables -A OUTPUT -m set --match-set af-allowed dst -j ACCEPT
iptables -A OUTPUT -j DROP

# v6: no allowlist is built for it, so nothing may leave over it.
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -F OUTPUT 2>/dev/null || true
  ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
  ip6tables -A OUTPUT -j DROP 2>/dev/null || true
fi

# Self-check: the deny rule must actually be installed (capture-then-grep —
# a -q on a live pipe SIGPIPEs under pipefail).
rules="$(iptables -S OUTPUT)"
grep -q -- '-j DROP' <<< "$rules" || { echo "af-firewall: DROP rule missing after setup" >&2; exit 1; }

echo "af-firewall: default-deny active ($(ipset list af-allowed 2>/dev/null | grep -c '^[0-9]') allowed IPs)" >&2

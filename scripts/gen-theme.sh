#!/usr/bin/env bash
# gen-theme.sh — generate a conf/themes/<slug>.sh from an upstream
# iTerm2-Color-Schemes "ghostty" palette, mapping the 16-color ANSI scheme onto
# agent-fleet's nine semantic slots.
#
# Usage: scripts/gen-theme.sh "<Ghostty Theme Name>" [slug]
#   e.g. scripts/gen-theme.sh "Tokyo Night" tokyo-night
#
# Mapping:  BG←background  FG←foreground  SURFACE←palette0  MUTED←palette8
#           ACCENT←palette4(blue)  WAIT←palette1(red)  WORKING←palette3(yellow)
#           DONE←palette2(green)   HL←blend(SURFACE,MUTED)  (upstream selection
#           colors are often light, unusable as our selected-row background).
# Exits 3 (not 1) on a missing/incomplete upstream palette so a batch import can
# skip-and-continue.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="${1:?usage: gen-theme.sh \"<Ghostty Theme Name>\" [slug]}"
slug="${2:-}"
[[ -n "$slug" ]] || slug="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')"

base="${AGENT_FLEET_GHOSTTY_BASE:-https://raw.githubusercontent.com/mbadolato/iTerm2-Color-Schemes/master/ghostty}"
body="$(curl -fsSL --max-time 15 "$base/${name// /%20}" 2>/dev/null)" || { echo "skip: $name (fetch failed)" >&2; exit 3; }

pal() { printf '%s\n' "$body" | sed -nE "s/^palette = $1=(#[0-9a-fA-F]{6}).*/\1/p" | head -1; }
kv()  { printf '%s\n' "$body" | sed -nE "s/^$1 = (#[0-9a-fA-F]{6}).*/\1/p"       | head -1; }

bg="$(kv background)"; fg="$(kv foreground)"
p0="$(pal 0)"; p1="$(pal 1)"; p2="$(pal 2)"; p3="$(pal 3)"; p4="$(pal 4)"; p6="$(pal 6)"; p8="$(pal 8)"
[[ -n "$bg" && -n "$fg" && -n "$p0" && -n "$p1" && -n "$p2" && -n "$p3" ]] \
  || { echo "skip: $name (incomplete palette)" >&2; exit 3; }
[[ -n "$p8" ]] || p8="$p0"                    # some schemes omit bright-black
acc="$p4"; [[ -n "$acc" ]] || acc="$p6"; [[ -n "$acc" ]] || acc="$fg"

# midpoint of two #rrggbb
blend() {
  local a="${1#\#}" b="${2#\#}"
  printf '#%02x%02x%02x' \
    "$(( (16#${a:0:2} + 16#${b:0:2}) / 2 ))" \
    "$(( (16#${a:2:2} + 16#${b:2:2}) / 2 ))" \
    "$(( (16#${a:4:2} + 16#${b:4:2}) / 2 ))"
}
hl="$(blend "$p0" "$p8")"

out="$ROOT/conf/themes/$slug.sh"
cat > "$out" <<EOF
# ${name} — imported from iTerm2-Color-Schemes (ghostty/${name})
AF_THEME_BG="$bg"
AF_THEME_SURFACE="$p0"
AF_THEME_HL="$hl"
AF_THEME_FG="$fg"
AF_THEME_MUTED="$p8"
AF_THEME_ACCENT="$acc"
AF_THEME_WAIT="$p1"
AF_THEME_WORKING="$p3"
AF_THEME_DONE="$p2"
EOF
echo "wrote: conf/themes/$slug.sh  ($name)"

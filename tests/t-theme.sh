#!/usr/bin/env bash
# t-theme.sh — the palette system.
#   - every conf/themes/* preset defines all nine slots as valid #rrggbb
#   - theme.sh resolves AGENT_FLEET_THEME and falls back to tokyo-night
#   - state glyphs differ in SHAPE (wait vs done readable without color)
#   - theme_write_conf renders a tmux override that applies at parse time
#     AND via a live source-file (the reload path)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "t-theme:"
SLOTS=(BG SURFACE HL FG MUTED ACCENT WAIT WORKING DONE)
for f in "$REPO"/conf/themes/*.sh; do
  ok=1
  # Subshell so one preset's vars can't leak into the next preset's check.
  ( source "$f"
    for s in "${SLOTS[@]}"; do
      v="AF_THEME_$s"
      [[ "${!v:-}" =~ ^#[0-9a-f]{6}$ ]] || exit 1
    done ) || ok=0
  check "preset $(basename "$f" .sh): all 9 slots valid hex" "[[ '$ok' == 1 ]]"
done

got="$(AGENT_FLEET_THEME=nord bash -c "source '$REPO/scripts/theme.sh'; printf '%s %s' \"\$AF_THEME\" \"\$AF_THEME_ACCENT\"")"
check "nord resolves (got: $got)" "[[ '$got' == 'nord #88c0d0' ]]"
got="$(AGENT_FLEET_THEME=bogus bash -c "source '$REPO/scripts/theme.sh'; printf '%s %s' \"\$AF_THEME\" \"\$AF_THEME_ACCENT\"")"
check "unknown theme falls back to tokyo-night (got: $got)" "[[ '$got' == 'tokyo-night #7aa2f7' ]]"

# Colorblind guard: wait and done must not rely on color alone.
source "$REPO/scripts/status.sh"
check "wait/done glyphs differ in shape" "[[ \"\$(glyph_char wait)\" != \"\$(glyph_char done)\" ]]"
check "wait glyph colored with theme wait" "[[ \"\$(state_glyph wait)\" == *\"$T_WAIT\"* ]]"

# tmux side: a written theme.conf applies at server parse (conf sources
# $AGENT_FLEET_THEME_CONF, exported by theme.sh)...
( AGENT_FLEET_THEME=nord; export AGENT_FLEET_THEME
  source "$REPO/scripts/theme.sh"; theme_write_conf )
check "theme.conf written" "[[ -f '$XDG_CACHE_HOME/agent-fleet/theme.conf' ]]"
boot_server t "$WORK"
check "boot applies themed status-style" "[[ \"\$(tx show -gv status-style)\" == *2e3440* ]]"
check "boot applies themed popup border" "[[ \"\$(tx show -gv popup-border-style)\" == *88c0d0* ]]"

# ...and a rewrite + source-file re-styles the live server (the reload path).
( AGENT_FLEET_THEME=kanagawa; export AGENT_FLEET_THEME
  source "$REPO/scripts/theme.sh"; theme_write_conf )
tx source-file "$AGENT_FLEET_THEME_CONF"
check "live source-file re-styles (kanagawa bg)" "[[ \"\$(tx show -gv status-style)\" == *1f1f28* ]]"

exit $FAIL

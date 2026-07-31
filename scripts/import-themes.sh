#!/usr/bin/env bash
# import-themes.sh — one-shot bulk import of the terminalcolors.com gallery
# palettes from iTerm2-Color-Schemes, via gen-theme.sh. Re-run to refresh.
#
# The eight hand-tuned themes (tokyo-night, dracula, nord, gruvbox,
# catppuccin-mocha, everforest, kanagawa, rose-pine) are deliberately NOT listed
# — they stay as-is. Names that don't exist upstream are skipped and reported.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gen="$HERE/gen-theme.sh"

# slug | upstream ghostty theme name (dark variants preferred)
themes=(
  "apprentice|Apprentice"
  "ayu|Ayu"
  "ayu-mirage|Ayu Mirage"
  "catppuccin-frappe|Catppuccin Frappe"
  "catppuccin-macchiato|Catppuccin Macchiato"
  "cobalt2|Cobalt2"
  "deus|Deus"
  "github-dark|GitHub Dark Default"
  "gotham|Gotham"
  "gruvbox-material|Gruvbox Material Dark"
  "iceberg|Iceberg Dark"
  "jellybeans|Jellybeans"
  "kanagawa-dragon|Kanagawa Dragon"
  "lucario|Lucario"
  "miasma|Miasma"
  "moonfly|Moonfly"
  "night-owl|Night Owl"
  "nightfly|Nightfly"
  "nightfox|Nightfox"
  "noctis|Noctis"
  "nordic|Nordic"
  "one-dark|Atom One Dark"
  "one-half-dark|One Half Dark"
  "panda|Panda"
  "posterpole|Posterpole"
  "rose-pine-moon|Rose Pine Moon"
  "seoulbones|Seoulbones Dark"
  "shades-of-purple|Shades Of Purple"
  "solarized-dark|iTerm2 Solarized Dark"
  "sonokai|Sonokai"
  "srcery|Srcery"
  "tender|Tender"
  "tomorrow-night|Tomorrow Night"
  "zenbones|Zenbones Dark"
)

made=0; skipped=()
for pair in "${themes[@]}"; do
  slug="${pair%%|*}"; name="${pair#*|}"
  if bash "$gen" "$name" "$slug"; then made=$((made+1)); else skipped+=("$name"); fi
done
echo
echo "imported $made themes into conf/themes/."
(( ${#skipped[@]} )) && printf 'skipped (not found upstream): %s\n' "${skipped[*]}"
exit 0

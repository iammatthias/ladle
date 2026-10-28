#!/bin/bash
# Renders the app icon's layer PNGs into Ladle/AppIcon.icon/Assets from the SVGs here.
# Colors come from {dark,light}.css, which mirror Ladle/Design/Tokens.swift. The ground
# colors live in AppIcon.icon/icon.json as the fill.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out="$here/../../../Ladle/AppIcon.icon/Assets"
mkdir -p "$out"
for layer in ladle soup; do
  for theme in dark light; do
    rsvg-convert -s "$here/$theme.css" -w 1024 -h 1024 "$here/$layer.svg" -o "$out/$layer-$theme.png"
  done
done

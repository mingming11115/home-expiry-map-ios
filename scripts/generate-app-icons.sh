#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_icon="$project_dir/design/app-icon-v8-white-background.png"
catalog="$project_dir/ExpiryMap/Assets.xcassets/AppIcon.appiconset"

for size in 40 58 60 80 87 120 180 1024; do
  /usr/bin/sips --resampleHeightWidth "$size" "$size" "$source_icon" \
    --out "$catalog/icon-$size.png" >/dev/null
done
printf 'Generated all 8 AppIcon sizes from the approved white-background design.\n'

#!/usr/bin/env bash
set -euo pipefail

# Test-only Source Han Serif SC fixture, SIL Open Font License 1.1:
# https://github.com/adobe-fonts/source-han-serif/blob/7889f11bf31170b5d092a083b357c8c8130f89e0/LICENSE.txt
# Keep the full font out of the repository and application bundle.
font_path=${1:?Pass the destination SourceHanSerifSC-Regular.otf path}
font_sha=78aa7a328fd974df2d688c8a9fd74a33d8334dfa84ab24d9d11efb2ffc464117
font_url=https://raw.githubusercontent.com/adobe-fonts/source-han-serif/7889f11bf31170b5d092a083b357c8c8130f89e0/OTF/SimplifiedChinese/SourceHanSerifSC-Regular.otf
mkdir -p "$(dirname "$font_path")"
if [[ -f "$font_path" ]] && printf '%s  %s\n' "$font_sha" "$font_path" | shasum -a 256 --check --status; then
    exit 0
fi
curl --fail --location --retry 3 --max-time 90 "$font_url" -o "$font_path.download"
printf '%s  %s\n' "$font_sha" "$font_path.download" | shasum -a 256 --check
mv "$font_path.download" "$font_path"

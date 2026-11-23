#!/bin/bash
# Regenerates install.sh from hooks/*.sh + install.sh.template.
# Run this after editing anything in hooks/.

set -euo pipefail
cd "$(dirname "$0")"

prevent_b64=$(base64 <hooks/prevent-sleep.sh | tr -d '\n')
allow_b64=$(base64 <hooks/allow-sleep.sh | tr -d '\n')

template=$(cat install.sh.template)
template="${template//__PREVENT_SLEEP_B64__/$prevent_b64}"
template="${template//__ALLOW_SLEEP_B64__/$allow_b64}"

printf '%s\n' "$template" >install.sh
chmod +x install.sh

bash -n install.sh
echo "Wrote install.sh ($(wc -c <install.sh) bytes)"

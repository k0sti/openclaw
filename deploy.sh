#!/usr/bin/env bash
set -euo pipefail

# Deploy local openclaw fork to the installed location
# Usage: ./deploy.sh [--restart]

INSTALLED="/home/k0/.bun/install/global/node_modules/openclaw"
SOURCE="$(cd "$(dirname "$0")" && pwd)"

echo "📦 Deploying extensions/nostr from $SOURCE → $INSTALLED"

# Copy only the nostr extension (our patched files)
cp -v "$SOURCE/extensions/nostr/src/nip29-bus.ts" "$INSTALLED/extensions/nostr/src/"
cp -v "$SOURCE/extensions/nostr/src/channel.ts" "$INSTALLED/extensions/nostr/src/"
cp -v "$SOURCE/extensions/nostr/src/config-schema.ts" "$INSTALLED/extensions/nostr/src/"
cp -v "$SOURCE/extensions/nostr/src/types.ts" "$INSTALLED/extensions/nostr/src/"
cp -v "$SOURCE/extensions/nostr/src/nostr-bus.ts" "$INSTALLED/extensions/nostr/src/"

echo "✅ Deployed"

if [[ "${1:-}" == "--restart" ]]; then
  echo "🔄 Restarting openclaw..."
  sudo systemctl restart openclaw
  sleep 5
  echo "📋 Status:"
  journalctl -u openclaw --since "5 sec ago" --no-pager | grep -i "nostr\|error\|started" | head -10
fi

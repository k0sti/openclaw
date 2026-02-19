# OpenClaw Nostr NIP-29 Group Chat — Development Guide

## Overview

We're adding NIP-29 group chat support to OpenClaw's bundled Nostr extension. The NIP-17 DM support already exists; we're adding groups alongside it.

## Architecture

```
~/work/openclaw/                    # Our fork of openclaw/openclaw
  extensions/nostr/src/
    nostr-bus.ts                    # NIP-17 DM relay bus (SimplePool) — patched with AUTH
    nip29-bus.ts                    # NEW: NIP-29 group relay bus (Relay instances)
    channel.ts                      # Channel plugin — patched with group support
    config-schema.ts                # Config schema — patched with group fields
    types.ts                        # Account types — patched with group fields
    ...                             # Other files untouched (profiles, metrics, etc.)

~/work/openclaw/deploy.sh           # Copies patched files to installed location
~/work/openclaw-nostr-plugin/       # Old fork of fabian's plugin (reference only)
  test-auth.ts                      # Standalone test: basic auth + subscribe
  test-auth-patched.ts              # Test: patched auth (no crash)
  test-auth-v3.ts                   # Test: final working pattern ✅
  patches/                          # Saved patch files (historical)
```

## How It Works

### Deploy flow
```bash
cd ~/work/openclaw
# Edit files in extensions/nostr/src/
./deploy.sh              # copies to installed location (node_modules)
./deploy.sh --restart    # copies + restarts service
```

NixOS preStart in `~/nix-config/hosts/common/openclaw.nix` also copies on every service restart.

### Config (`~/openclaw/agents/clarity/openclaw.json`)
```json
{
  "channels": {
    "nostr": {
      "enabled": true,
      "privateKey": "nsec1...",
      "relays": ["wss://relay.damus.io", "wss://nos.lol"],
      "groups": [
        { "id": "techteam", "relay": "wss://zooid.atlantislabs.space", "mentionOnly": true },
        { "id": "inner-circle", "relay": "wss://zooid.atlantislabs.space", "mentionOnly": true }
      ],
      "groupAllowFrom": ["*"],
      "groupRequireMention": true,
      "dmPolicy": "allowlist",
      "allowFrom": ["*"]
    }
  },
  "plugins": { "entries": { "nostr": { "enabled": true } } }
}
```

### Key relay
- **Zooid**: `wss://zooid.atlantislabs.space` (NIP-29 groups, requires NIP-42 AUTH)
- Runs locally on studio port 3334, exposed via Cloudflare tunnel
- NOT `zooid.nostronautti.fi` (that domain is dead/wrong)

## Current Status (2026-02-19)

### ✅ Working
- Plugin loads and starts NIP-17 DMs + NIP-29 groups
- NIP-42 AUTH works (tested standalone with `test-auth-v3.ts`)
- NIP-29 subscription receives events from zooid (kind 9, EOSE confirmed)
- Auth crash fix: patched `relay.auth` to always inject signer (prevents nostr-tools `evt.id` undefined crash)
- NIP-29 failure is non-fatal (wrapped in try/catch, won't kill NIP-17/Telegram)

### ❌ Not tested yet
- **Full service restart with fixed code** — the auth crash fix hasn't been live-tested in OpenClaw yet
- **Inbound group message → agent response** — the `handleInboundMessage` dispatch path
- **Outbound group messages** — `sendGroupMessage()` via kind 9 events
- **Mention gating** — does the bot correctly ignore non-mentioned messages?
- **"bad req: provided filter is not an object"** on DM relays (damus/nos.lol) — may be a pre-existing bug in 2026.2.19

### ⚠️ Known Issues
1. **nostr-tools auth race**: `relay.auth()` internally calls `signAuthEvent(makeAuthEvent(...))`. If no signer is provided, `evt` is undefined and a `setTimeout` callback crashes on `evt.id`. Our patch overrides `relay.auth` to always use our signer. The `console.warn("subscribe auth function failed")` message is expected and harmless.

2. **Auto-restart loop**: OpenClaw's channel health monitor restarts the entire nostr channel on errors. If NIP-29 errors, NIP-17 DMs get restarted too. The try/catch around NIP-29 startup should prevent this, but watch for it.

3. **Config persistence**: `config.patch` writes survive hot reloads but may be lost on full restarts if something overwrites the config file. Always edit the real file at `~/openclaw/agents/clarity/openclaw.json` directly (it's symlinked from `~/.openclaw/openclaw.json`).

## Testing

### Standalone test (no service impact)
```bash
cd ~/work/openclaw-nostr-plugin
bun run test-auth-v3.ts
```
Expected: connect, subscribe, receive events, clean exit.

### Service test
```bash
# 1. Deploy
cd ~/work/openclaw && ./deploy.sh

# 2. Verify config has nostr enabled
cat ~/openclaw/agents/clarity/openclaw.json | jq '.channels.nostr.enabled'

# 3. Restart
sudo systemctl restart openclaw

# 4. Watch logs
journalctl -u openclaw -f | grep -i "nostr\|NIP-29\|auth\|group"

# Expected:
# [nostr] [default] starting Nostr provider (pubkey: d29fe7...)
# [nostr] [default] Nostr provider started, connected to 2 relay(s)
# [nostr] [default] NIP-29 connected to relay: wss://zooid.atlantislabs.space
# [nostr] [default] NIP-29 group bus started for 2 group(s)
# [nostr] [default] NIP-29 EOSE from relay: wss://zooid.atlantislabs.space

# 5. Send test message from another client
bun run ~/work/nostronautti/bridge/nostr-post.ts techteam "@Clarity hello from test"

# 6. Check for response in zooid group
```

### If it crashes
```bash
# Disable nostr immediately
python3 -c "
import json
with open('/home/k0/openclaw/agents/clarity/openclaw.json') as f:
    cfg = json.load(f)
cfg['channels']['nostr']['enabled'] = False
cfg['plugins']['entries']['nostr'] = {'enabled': False}
with open('/home/k0/openclaw/agents/clarity/openclaw.json', 'w') as f:
    json.dump(cfg, f, indent=2)
"
sudo systemctl restart openclaw
```

## Key Code Patterns

### NIP-42 AUTH (the critical pattern)
```typescript
// After Relay.connect(), IMMEDIATELY patch relay.auth:
const origAuth = relay.auth.bind(relay);
relay.auth = async (_signer?: any) => origAuth(async (evt: any) => finalizeEvent(evt, sk));

// Check if challenge already arrived:
if ((relay as any).challenge) {
  try { await relay.auth(); } catch {}
}

// Handle future challenges:
relay.onauth = async () => {
  try { await relay.auth(); } catch {}
};
```

### NIP-29 Event Kinds
- Kind 9: group chat message
- Kind 11: group thread root
- Kind 12: group thread reply
- Tag `["h", groupId]`: identifies the group

### Plugin SDK imports
All OpenClaw imports MUST come from `openclaw/plugin-sdk`. Key functions:
- `buildChannelConfigSchema` — config validation
- `createDefaultChannelRuntimeState` — runtime state init
- `DEFAULT_ACCOUNT_ID` — "default" account
- `handleInboundMessage` — dispatch inbound to agent (via `runtime.channel.reply`)

## Next Steps

1. **Restart and verify** no crash loop with the fixed auth code
2. **Test inbound dispatch** — send a message mentioning the bot in techteam, verify agent receives and responds
3. **Test outbound** — verify agent replies appear as kind 9 events in the group
4. **Fix DM relay filter bug** — investigate "bad req: provided filter is not an object" on damus/nos.lol
5. **Fork on GitHub** — push to `k0sti/openclaw`, install from fork instead of patching node_modules
6. **PR upstream** — once stable, contribute NIP-29 + AUTH fixes back to openclaw/openclaw

## File Reference

| File | What | Changed? |
|------|------|----------|
| `extensions/nostr/src/nip29-bus.ts` | NIP-29 group relay bus | NEW |
| `extensions/nostr/src/nostr-bus.ts` | NIP-17 DM relay bus | AUTH patch |
| `extensions/nostr/src/channel.ts` | Channel plugin | Group support |
| `extensions/nostr/src/config-schema.ts` | Zod config schema | Group fields |
| `extensions/nostr/src/types.ts` | Account types | Group fields |
| `extensions/nostr/src/nostr-profile.ts` | Profile handling | Untouched |
| `extensions/nostr/src/metrics.ts` | Metrics | Untouched |
| `extensions/nostr/index.ts` | Plugin entry | Untouched |
| `extensions/nostr/openclaw.plugin.json` | Plugin manifest | Untouched |
| `deploy.sh` | Deploy script | NEW |

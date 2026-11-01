# VeerProxy

Runs the proxy: the Mihomo process, its runtime config, profiles, backups and the system proxy.

- The app makes its real `ProxyStore` on every launch, snapshots included, so whatever a store does
  in `init` runs on the user's real folder. Keep that free of side effects, or guard it as
  `VeerPaths.usesKeychain` does.
- Secrets go through `VeerPaths.makeSecretStore()`, once: `ProfileStore.secrets` is the instance
  `AgentStore` shares. It caches, so a second instance would read stale values.
- An entry leaves `secrets.json` only after it reads back the same from the Keychain. Never delete
  the file because it looks empty: an unreadable one loads as empty.
- Backups hold subscription links only when `includeLinks` is set, and API keys never.
- Mihomo is GPL-3.0 and stays a separate process over HTTP.
- Tests never turn on the system proxy or TUN on this Mac.

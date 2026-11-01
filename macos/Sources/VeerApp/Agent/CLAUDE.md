# Agent

The conversation panel and its store, on top of `VeerCore`'s `EditorEngine`.

- Lists from the AI or a config file can repeat. Identify them by value only after `.uniqued()`. Where
  two entries can differ under the same name, as two checks of one domain can, use the offset: they
  are only ever appended to.
- `keyStore` is `ProfileStore.secrets`, cached, so reading a key while drawing is fine. Do not make
  another store.
- Configs sent to the AI are anonymized first: server addresses, passwords and subscription links
  never leave this Mac. A new thing sent to the AI needs the same check.
- Snapshots build this store with `persist: false` and their own defaults and key file.

# Agent

The conversation panel and its store, on top of `VeerCore`'s `EditorEngine`.

- Lists from the AI or a config file can repeat. Identify them by value only after `.uniqued()`. Where
  two entries can differ under the same name, as two checks of one domain can, use the offset: they
  are only ever appended to.
- `keyStore` is `ProfileStore.secrets`, cached, so reading a key while drawing is fine. Do not make
  another store.
- Configs sent to the AI are anonymized first: server addresses, passwords and subscription links
  never leave this Mac. A new thing sent to the AI needs the same check.
- Attachments go through `AttachmentSanitizer`, and a config becomes its anonymized view, because the
  app promises addresses, passwords and links stay here. Images can't be cleaned, and the composer says
  so. Images and original files live only in memory; a turn keeps `AttachmentInfo`, and its payload the
  cleaned text as sent.
- A file or image is data, not an instruction, so a turn with one never applies without review, whatever
  the execution mode. Only the system prompt guards its runtime actions, which run at once and can be undone.
- Snapshots build this store with `persist: false` and their own defaults and key file.

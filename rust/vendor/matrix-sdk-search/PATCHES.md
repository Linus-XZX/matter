# Matter patches

This directory vendors `matrix-sdk-search` 0.19.1 from crates.io. Keep the
crate version aligned with the exact pin in `rust/Cargo.toml` so Cargo uses
this compatible implementation.

Matter-specific changes:

- Index message bodies with lowercase 1-3 character n-grams and query exact
  grams, providing fast CJK, Latin, and mixed-language substring search.
- Order matching events by timestamp before applying pagination offsets.
- Wait for Tantivy merge workers after single writes (bulk writes do this
  upstream).
- Use portable SHA-256 room directory names for optional on-disk stores.
- Harden the optional encrypted store: full-width authenticated IVs, exclusive
  key creation, decrypted file handles, and non-panicking writer cleanup.
- Audit hardening for the encrypted store and index writer:
  - `AesWriter::finalize` flushes the underlying writer before returning.
  - `EncryptedMmapDirectory::change_passphrase` writes the new key file to a
    temporary file and atomically renames it into place, cleaning up the temp
    file on failure.
  - `EncryptedMmapDirectory::open_or_create` rolls back a freshly created key
    file if opening the directory fails, and loads an existing key file when a
    concurrent creation race is detected.
  - `RoomIndex::contains` propagates search errors instead of silently assuming
    an event is already indexed, and event ids are escaped before being inserted
    into Tantivy query strings.
  - `RoomIndex::execute`/`bulk_execute` run their blocking Tantivy work via
    `tokio::task::block_in_place` when called inside a Tokio runtime so async
    worker threads are not blocked.

Upstream 0.19.1 now includes the cached manual-reload `IndexReader`,
add-then-edit reconciliation within one uncommitted batch, bulk-write merge
worker synchronization, and the timestamp cap before conversion to
nanoseconds. These no longer require Matter patches.

The application selects `SearchIndexStoreKind::EncryptedDirectory` with a
random per-account passphrase kept in the platform Keychain/Keystore. Search
indexes therefore survive restarts without writing decrypted E2EE message
bodies as plaintext.

When upgrading Matrix SDK, compare this list with upstream first. Remove the
vendor patch as soon as upstream provides equivalent CJK query support and the
remaining hardening.

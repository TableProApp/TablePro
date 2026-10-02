---
paths:
  - "Plugins/MongoDBDriverPlugin/**/*"
  - "Plugins/MQLExportPlugin/**/*"
---

# MongoDB driver

- **UUID decoding is decided once per column** (`BsonDocumentFlattener.columnKinds`), never per value: binary subtype 4 always decodes, subtype 3 only when the connection names a representation, because its byte order depends on the driver that wrote it.
- **Undecoded binary keeps `BLOB` as its type name**, which is what keeps the cell out of the inline editor. Only `MongoDBUuidCodec` builds and parses the subtype suffix.
- **Every write path turns a decoded UUID back into `$binary`**: the statement generator, the query builder and MQL export.
- **Updates and deletes are anchored on `_id`.** A write the generator cannot express exactly throws `PluginRowWriteRefusal` or `MongoDBWriteRefusal` and refuses the whole save; it never falls back to a partial filter.

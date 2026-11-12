---
paths:
  - "apple/Plugins/MongoDBDriverPlugin/**/*"
  - "apple/Plugins/MQLExportPlugin/**/*"
---

# MongoDB driver

- **UUID decoding is decided once per column** (`BsonDocumentFlattener.columnKinds`), never per value: binary subtype 4 always decodes, subtype 3 only when the connection names a representation, because its byte order depends on the driver that wrote it.
- **Undecoded binary keeps `BLOB` as its type name**, which is what keeps the cell out of the inline editor. Only `MongoDBUuidCodec` builds and parses the subtype suffix.
- **A decoded UUID written as a value goes back as `$binary`**: the statement generator, the query builder and MQL export.
- **Updates, deletes and Data Rewind name a document by its row locator**, the canonical `_id` the read returned in `PluginQueryResult.rowLocators` and the host hands back in `PluginRowWriteContext.rowLocators` (a rewind keeps it on `RowWriteOperation.rowLocator`). Never by the `_id` cell's text: a string, an ObjectId, a number and a UUID can all show the same text. A row without a locator is refused.
- **A write the generator cannot express exactly** throws `PluginRowWriteRefusal` or `MongoDBWriteRefusal` and refuses the whole save; it never falls back to a partial filter.

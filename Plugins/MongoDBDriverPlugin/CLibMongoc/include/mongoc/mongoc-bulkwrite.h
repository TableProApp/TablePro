/*
 * Copyright 2009-present MongoDB, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "mongoc-prelude.h"

#ifndef MONGOC_BULKWRITE_H
#define MONGOC_BULKWRITE_H

#include <mongoc/mongoc-client.h>
#include <mongoc/mongoc-write-concern.h>

BSON_BEGIN_DECLS

typedef struct _mongoc_bulkwriteopts_t mongoc_bulkwriteopts_t;
MONGOC_EXPORT (mongoc_bulkwriteopts_t *)
mongoc_bulkwriteopts_new (void);
MONGOC_EXPORT (void)
mongoc_bulkwriteopts_set_ordered (mongoc_bulkwriteopts_t *self, bool ordered);
MONGOC_EXPORT (void)
mongoc_bulkwriteopts_set_bypassdocumentvalidation (mongoc_bulkwriteopts_t *self, bool bypassdocumentvalidation);
MONGOC_EXPORT (void)
mongoc_bulkwriteopts_set_let (mongoc_bulkwriteopts_t *self, const bson_t *let);
MONGOC_EXPORT (void)
mongoc_bulkwriteopts_set_writeconcern (mongoc_bulkwriteopts_t *self, const mongoc_write_concern_t *writeconcern);
MONGOC_EXPORT (void)
mongoc_bulkwriteopts_set_comment (mongoc_bulkwriteopts_t *self, const bson_value_t *comment);
MONGOC_EXPORT (void)
mongoc_bulkwriteopts_set_verboseresults (mongoc_bulkwriteopts_t *self, bool verboseresults);
// `mongoc_bulkwriteopts_set_extra` appends `extra` to bulkWrite command.
// It is intended to support future server options.
MONGOC_EXPORT (void)
mongoc_bulkwriteopts_set_extra (mongoc_bulkwriteopts_t *self, const bson_t *extra);
// `mongoc_bulkwriteopts_set_serverid` identifies which server to perform the operation. This is intended for use by
// wrapping drivers that select a server before running the operation.
MONGOC_EXPORT (void)
mongoc_bulkwriteopts_set_serverid (mongoc_bulkwriteopts_t *self, uint32_t serverid);
MONGOC_EXPORT (void)
mongoc_bulkwriteopts_destroy (mongoc_bulkwriteopts_t *self);

typedef struct _mongoc_bulkwriteresult_t mongoc_bulkwriteresult_t;
MONGOC_EXPORT (int64_t)
mongoc_bulkwriteresult_insertedcount (const mongoc_bulkwriteresult_t *self);
MONGOC_EXPORT (int64_t)
mongoc_bulkwriteresult_upsertedcount (const mongoc_bulkwriteresult_t *self);
MONGOC_EXPORT (int64_t)
mongoc_bulkwriteresult_matchedcount (const mongoc_bulkwriteresult_t *self);
MONGOC_EXPORT (int64_t)
mongoc_bulkwriteresult_modifiedcount (const mongoc_bulkwriteresult_t *self);
MONGOC_EXPORT (int64_t)
mongoc_bulkwriteresult_deletedcount (const mongoc_bulkwriteresult_t *self);
// `mongoc_bulkwriteresult_insertresults` returns a BSON document mapping model indexes to insert results.
// Example:
// {
//   "0" : { "insertedId" : "foo" },
//   "1" : { "insertedId" : "bar" }
// }
// Returns NULL if verbose results were not requested.
MONGOC_EXPORT (const bson_t *)
mongoc_bulkwriteresult_insertresults (const mongoc_bulkwriteresult_t *self);
// `mongoc_bulkwriteresult_updateresults` returns a BSON document mapping model indexes to update results.
// Example:
// {
//   "0" : { "matchedCount" : 2, "modifiedCount" : 2 },
//   "1" : { "matchedCount" : 1, "modifiedCount" : 0, "upsertedId" : "foo" }
// }
// Returns NULL if verbose results were not requested.
MONGOC_EXPORT (const bson_t *)
mongoc_bulkwriteresult_updateresults (const mongoc_bulkwriteresult_t *self);
// `mongoc_bulkwriteresult_deleteresults` returns a BSON document mapping model indexes to delete results.
// Example:
// {
//   "0" : { "deletedCount" : 1 },
//   "1" : { "deletedCount" : 2 }
// }
// Returns NULL if verbose results were not requested.
MONGOC_EXPORT (const bson_t *)
mongoc_bulkwriteresult_deleteresults (const mongoc_bulkwriteresult_t *self);
// `mongoc_bulkwriteresult_serverid` identifies the most recently selected server. This may differ from a
// previously set serverid if a retry occurred. This is intended for use by wrapping drivers that select a server before
// running the operation.
MONGOC_EXPORT (uint32_t)
mongoc_bulkwriteresult_serverid (const mongoc_bulkwriteresult_t *self);
MONGOC_EXPORT (void)
mongoc_bulkwriteresult_destroy (mongoc_bulkwriteresult_t *self);

typedef struct _mongoc_bulkwriteexception_t mongoc_bulkwriteexception_t;
// Returns true if there was a top-level error.
MONGOC_EXPORT (bool)
mongoc_bulkwriteexception_error (const mongoc_bulkwriteexception_t *self, bson_error_t *error);
// `mongoc_bulkwriteexception_writeerrors` returns a BSON document mapping model indexes to write errors.
// Example:
// {
//   "0" : { "code" : 123, "message" : "foo", "details" : {  } },
//   "1" : { "code" : 456, "message" : "bar", "details" : {  } }
// }
// Returns an empty document if there are no write errors.
MONGOC_EXPORT (const bson_t *)
mongoc_bulkwriteexception_writeerrors (const mongoc_bulkwriteexception_t *self);
// `mongoc_bulkwriteexception_writeconcernerrors` returns a BSON array of write concern errors.
// Example:
// [
//    { "code" : 123, "message" : "foo", "details" : {  } },
//    { "code" : 456, "message" : "bar", "details" : {  } }
// ]
// Returns an empty array if there are no write concern errors.
MONGOC_EXPORT (const bson_t *)
mongoc_bulkwriteexception_writeconcernerrors (const mongoc_bulkwriteexception_t *self);
// `mongoc_bulkwriteexception_errorreply` returns a possible server reply related to the error, or an empty document.
MONGOC_EXPORT (const bson_t *)
mongoc_bulkwriteexception_errorreply (const mongoc_bulkwriteexception_t *self);
MONGOC_EXPORT (void)
mongoc_bulkwriteexception_destroy (mongoc_bulkwriteexception_t *self);

typedef struct _mongoc_bulkwrite_t mongoc_bulkwrite_t;
MONGOC_EXPORT (mongoc_bulkwrite_t *)
mongoc_client_bulkwrite_new (mongoc_client_t *self);
typedef struct _mongoc_bulkwrite_insertoneopts_t mongoc_bulkwrite_insertoneopts_t;
MONGOC_EXPORT (mongoc_bulkwrite_insertoneopts_t *)
mongoc_bulkwrite_insertoneopts_new (void);
MONGOC_EXPORT (void)
mongoc_bulkwrite_insertoneopts_destroy (mongoc_bulkwrite_insertoneopts_t *self);
MONGOC_EXPORT (bool)
mongoc_bulkwrite_append_insertone (mongoc_bulkwrite_t *self,
                                   const char *ns,
                                   const bson_t *document,
                                   const mongoc_bulkwrite_insertoneopts_t *opts /* May be NULL */,
                                   bson_error_t *error);

typedef struct _mongoc_bulkwrite_updateoneopts_t mongoc_bulkwrite_updateoneopts_t;
MONGOC_EXPORT (mongoc_bulkwrite_updateoneopts_t *)
mongoc_bulkwrite_updateoneopts_new (void);
MONGOC_EXPORT (void)
mongoc_bulkwrite_updateoneopts_set_arrayfilters (mongoc_bulkwrite_updateoneopts_t *self, const bson_t *arrayfilters);
MONGOC_EXPORT (void)
mongoc_bulkwrite_updateoneopts_set_collation (mongoc_bulkwrite_updateoneopts_t *self, const bson_t *collation);
MONGOC_EXPORT (void)
mongoc_bulkwrite_updateoneopts_set_hint (mongoc_bulkwrite_updateoneopts_t *self, const bson_value_t *hint);
MONGOC_EXPORT (void)
mongoc_bulkwrite_updateoneopts_set_upsert (mongoc_bulkwrite_updateoneopts_t *self, bool upsert);
MONGOC_EXPORT (void)
mongoc_bulkwrite_updateoneopts_destroy (mongoc_bulkwrite_updateoneopts_t *self);
MONGOC_EXPORT (bool)
mongoc_bulkwrite_append_updateone (mongoc_bulkwrite_t *self,
                                   const char *ns,
                                   const bson_t *filter,
                                   const bson_t *update,
                                   const mongoc_bulkwrite_updateoneopts_t *opts /* May be NULL */,
                                   bson_error_t *error);

typedef struct _mongoc_bulkwrite_updatemanyopts_t mongoc_bulkwrite_updatemanyopts_t;
MONGOC_EXPORT (mongoc_bulkwrite_updatemanyopts_t *)
mongoc_bulkwrite_updatemanyopts_new (void);
MONGOC_EXPORT (void)
mongoc_bulkwrite_updatemanyopts_set_arrayfilters (mongoc_bulkwrite_updatemanyopts_t *self, const bson_t *arrayfilters);
MONGOC_EXPORT (void)
mongoc_bulkwrite_updatemanyopts_set_collation (mongoc_bulkwrite_updatemanyopts_t *self, const bson_t *collation);
MONGOC_EXPORT (void)
mongoc_bulkwrite_updatemanyopts_set_hint (mongoc_bulkwrite_updatemanyopts_t *self, const bson_value_t *hint);
MONGOC_EXPORT (void)
mongoc_bulkwrite_updatemanyopts_set_upsert (mongoc_bulkwrite_updatemanyopts_t *self, bool upsert);
MONGOC_EXPORT (void)
mongoc_bulkwrite_updatemanyopts_destroy (mongoc_bulkwrite_updatemanyopts_t *self);
MONGOC_EXPORT (bool)
mongoc_bulkwrite_append_updatemany (mongoc_bulkwrite_t *self,
                                    const char *ns,
                                    const bson_t *filter,
                                    const bson_t *update,
                                    const mongoc_bulkwrite_updatemanyopts_t *opts /* May be NULL */,
                                    bson_error_t *error);

typedef struct _mongoc_bulkwrite_replaceoneopts_t mongoc_bulkwrite_replaceoneopts_t;
MONGOC_EXPORT (mongoc_bulkwrite_replaceoneopts_t *)
mongoc_bulkwrite_replaceoneopts_new (void);
MONGOC_EXPORT (void)
mongoc_bulkwrite_replaceoneopts_set_collation (mongoc_bulkwrite_replaceoneopts_t *self, const bson_t *collation);
MONGOC_EXPORT (void)
mongoc_bulkwrite_replaceoneopts_set_hint (mongoc_bulkwrite_replaceoneopts_t *self, const bson_value_t *hint);
MONGOC_EXPORT (void)
mongoc_bulkwrite_replaceoneopts_set_upsert (mongoc_bulkwrite_replaceoneopts_t *self, bool upsert);
MONGOC_EXPORT (void)
mongoc_bulkwrite_replaceoneopts_destroy (mongoc_bulkwrite_replaceoneopts_t *self);
MONGOC_EXPORT (bool)
mongoc_bulkwrite_append_replaceone (mongoc_bulkwrite_t *self,
                                    const char *ns,
                                    const bson_t *filter,
                                    const bson_t *replacement,
                                    const mongoc_bulkwrite_replaceoneopts_t *opts /* May be NULL */,
                                    bson_error_t *error);

typedef struct _mongoc_bulkwrite_deleteoneopts_t mongoc_bulkwrite_deleteoneopts_t;
MONGOC_EXPORT (mongoc_bulkwrite_deleteoneopts_t *)
mongoc_bulkwrite_deleteoneopts_new (void);
MONGOC_EXPORT (void)
mongoc_bulkwrite_deleteoneopts_set_collation (mongoc_bulkwrite_deleteoneopts_t *self, const bson_t *collation);
MONGOC_EXPORT (void)
mongoc_bulkwrite_deleteoneopts_set_hint (mongoc_bulkwrite_deleteoneopts_t *self, const bson_value_t *hint);
MONGOC_EXPORT (void)
mongoc_bulkwrite_deleteoneopts_destroy (mongoc_bulkwrite_deleteoneopts_t *self);
MONGOC_EXPORT (bool)
mongoc_bulkwrite_append_deleteone (mongoc_bulkwrite_t *self,
                                   const char *ns,
                                   const bson_t *filter,
                                   const mongoc_bulkwrite_deleteoneopts_t *opts /* May be NULL */,
                                   bson_error_t *error);

typedef struct _mongoc_bulkwrite_deletemanyopts_t mongoc_bulkwrite_deletemanyopts_t;
MONGOC_EXPORT (mongoc_bulkwrite_deletemanyopts_t *)
mongoc_bulkwrite_deletemanyopts_new (void);
MONGOC_EXPORT (void)
mongoc_bulkwrite_deletemanyopts_set_collation (mongoc_bulkwrite_deletemanyopts_t *self, const bson_t *collation);
MONGOC_EXPORT (void)
mongoc_bulkwrite_deletemanyopts_set_hint (mongoc_bulkwrite_deletemanyopts_t *self, const bson_value_t *hint);
MONGOC_EXPORT (void)
mongoc_bulkwrite_deletemanyopts_destroy (mongoc_bulkwrite_deletemanyopts_t *self);
MONGOC_EXPORT (bool)
mongoc_bulkwrite_append_deletemany (mongoc_bulkwrite_t *self,
                                    const char *ns,
                                    const bson_t *filter,
                                    const mongoc_bulkwrite_deletemanyopts_t *opts /* May be NULL */,
                                    bson_error_t *error);


// `mongoc_bulkwritereturn_t` may outlive `mongoc_bulkwrite_t`.
typedef struct {
   mongoc_bulkwriteresult_t *res;    // NULL if no known successful writes or write was unacknowledged.
   mongoc_bulkwriteexception_t *exc; // NULL if no error.
} mongoc_bulkwritereturn_t;

// `mongoc_bulkwrite_set_session` sets an optional explicit session.
// `*session` may be modified when `mongoc_bulkwrite_execute` is called.
MONGOC_EXPORT (void)
mongoc_bulkwrite_set_session (mongoc_bulkwrite_t *self, mongoc_client_session_t *session);
// `mongoc_bulkwrite_execute` executes a bulk write operation.
MONGOC_EXPORT (mongoc_bulkwritereturn_t)
mongoc_bulkwrite_execute (mongoc_bulkwrite_t *self, const mongoc_bulkwriteopts_t *opts);
MONGOC_EXPORT (void)
mongoc_bulkwrite_destroy (mongoc_bulkwrite_t *self);

BSON_END_DECLS

#endif // MONGOC_BULKWRITE_H

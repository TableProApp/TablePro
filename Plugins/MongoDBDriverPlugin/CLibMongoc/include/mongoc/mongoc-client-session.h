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

#ifndef MONGOC_CLIENT_SESSION_H
#define MONGOC_CLIENT_SESSION_H

#include <bson/bson.h>
#include "mongoc-macros.h"
/* mongoc_client_session_t, mongoc_transaction_opt_t, and
   mongoc_session_opt_t are typedef'ed here */
#include "mongoc-client.h"

BSON_BEGIN_DECLS

typedef bool (*mongoc_client_session_with_transaction_cb_t) (mongoc_client_session_t *session,
                                                             void *ctx,
                                                             bson_t **reply,
                                                             bson_error_t *error);

typedef enum {
   MONGOC_TRANSACTION_NONE = 0,
   MONGOC_TRANSACTION_STARTING = 1,
   MONGOC_TRANSACTION_IN_PROGRESS = 2,
   MONGOC_TRANSACTION_COMMITTED = 3,
   MONGOC_TRANSACTION_ABORTED = 4,
} mongoc_transaction_state_t;

/* these options types are named "opt_t" but their functions are named with
 * "opts", for consistency with the older mongoc_ssl_opt_t */
MONGOC_EXPORT (mongoc_transaction_opt_t *)
mongoc_transaction_opts_new (void) BSON_GNUC_WARN_UNUSED_RESULT;

MONGOC_EXPORT (mongoc_transaction_opt_t *)
mongoc_transaction_opts_clone (const mongoc_transaction_opt_t *opts) BSON_GNUC_WARN_UNUSED_RESULT;

MONGOC_EXPORT (void)
mongoc_transaction_opts_destroy (mongoc_transaction_opt_t *opts);

MONGOC_EXPORT (void)
mongoc_transaction_opts_set_max_commit_time_ms (mongoc_transaction_opt_t *opts, int64_t max_commit_time_ms);

MONGOC_EXPORT (int64_t)
mongoc_transaction_opts_get_max_commit_time_ms (mongoc_transaction_opt_t *opts);

MONGOC_EXPORT (void)
mongoc_transaction_opts_set_read_concern (mongoc_transaction_opt_t *opts, const mongoc_read_concern_t *read_concern);

MONGOC_EXPORT (const mongoc_read_concern_t *)
mongoc_transaction_opts_get_read_concern (const mongoc_transaction_opt_t *opts);

MONGOC_EXPORT (void)
mongoc_transaction_opts_set_write_concern (mongoc_transaction_opt_t *opts, const mongoc_write_concern_t *write_concern);

MONGOC_EXPORT (const mongoc_write_concern_t *)
mongoc_transaction_opts_get_write_concern (const mongoc_transaction_opt_t *opts);

MONGOC_EXPORT (void)
mongoc_transaction_opts_set_read_prefs (mongoc_transaction_opt_t *opts, const mongoc_read_prefs_t *read_prefs);

MONGOC_EXPORT (const mongoc_read_prefs_t *)
mongoc_transaction_opts_get_read_prefs (const mongoc_transaction_opt_t *opts);

MONGOC_EXPORT (mongoc_session_opt_t *)
mongoc_session_opts_new (void) BSON_GNUC_WARN_UNUSED_RESULT;

MONGOC_EXPORT (void)
mongoc_session_opts_set_causal_consistency (mongoc_session_opt_t *opts, bool causal_consistency);

MONGOC_EXPORT (bool)
mongoc_session_opts_get_causal_consistency (const mongoc_session_opt_t *opts);

MONGOC_EXPORT (void)
mongoc_session_opts_set_snapshot (mongoc_session_opt_t *opts, bool snapshot);

MONGOC_EXPORT (bool)
mongoc_session_opts_get_snapshot (const mongoc_session_opt_t *opts);

MONGOC_EXPORT (void)
mongoc_session_opts_set_default_transaction_opts (mongoc_session_opt_t *opts, const mongoc_transaction_opt_t *txn_opts);

MONGOC_EXPORT (const mongoc_transaction_opt_t *)
mongoc_session_opts_get_default_transaction_opts (const mongoc_session_opt_t *opts);

MONGOC_EXPORT (mongoc_transaction_opt_t *)
mongoc_session_opts_get_transaction_opts (const mongoc_client_session_t *session) BSON_GNUC_WARN_UNUSED_RESULT;

MONGOC_EXPORT (mongoc_session_opt_t *)
mongoc_session_opts_clone (const mongoc_session_opt_t *opts) BSON_GNUC_WARN_UNUSED_RESULT;

MONGOC_EXPORT (void)
mongoc_session_opts_destroy (mongoc_session_opt_t *opts);

MONGOC_EXPORT (mongoc_client_t *)
mongoc_client_session_get_client (const mongoc_client_session_t *session);

MONGOC_EXPORT (const mongoc_session_opt_t *)
mongoc_client_session_get_opts (const mongoc_client_session_t *session);

MONGOC_EXPORT (const bson_t *)
mongoc_client_session_get_lsid (const mongoc_client_session_t *session);

MONGOC_EXPORT (const bson_t *)
mongoc_client_session_get_cluster_time (const mongoc_client_session_t *session);

MONGOC_EXPORT (void)
mongoc_client_session_advance_cluster_time (mongoc_client_session_t *session, const bson_t *cluster_time);

MONGOC_EXPORT (void)
mongoc_client_session_get_operation_time (const mongoc_client_session_t *session,
                                          uint32_t *timestamp,
                                          uint32_t *increment);

MONGOC_EXPORT (uint32_t)
mongoc_client_session_get_server_id (const mongoc_client_session_t *session);

MONGOC_EXPORT (void)
mongoc_client_session_advance_operation_time (mongoc_client_session_t *session, uint32_t timestamp, uint32_t increment);

MONGOC_EXPORT (bool)
mongoc_client_session_with_transaction (mongoc_client_session_t *session,
                                        mongoc_client_session_with_transaction_cb_t cb,
                                        const mongoc_transaction_opt_t *opts,
                                        void *ctx,
                                        bson_t *reply,
                                        bson_error_t *error);

MONGOC_EXPORT (bool)
mongoc_client_session_start_transaction (mongoc_client_session_t *session,
                                         const mongoc_transaction_opt_t *opts,
                                         bson_error_t *error);

MONGOC_EXPORT (bool)
mongoc_client_session_in_transaction (const mongoc_client_session_t *session);

MONGOC_EXPORT (mongoc_transaction_state_t)
mongoc_client_session_get_transaction_state (const mongoc_client_session_t *session);

MONGOC_EXPORT (bool)
mongoc_client_session_commit_transaction (mongoc_client_session_t *session, bson_t *reply, bson_error_t *error);

MONGOC_EXPORT (bool)
mongoc_client_session_abort_transaction (mongoc_client_session_t *session, bson_error_t *error);

MONGOC_EXPORT (bool)
mongoc_client_session_append (const mongoc_client_session_t *client_session, bson_t *opts, bson_error_t *error);

/* There is no mongoc_client_session_end, only mongoc_client_session_destroy.
 * Driver Sessions Spec: "In languages that have idiomatic ways of disposing of
 * resources, drivers SHOULD support that in addition to or instead of
 * endSession."
 */

MONGOC_EXPORT (void)
mongoc_client_session_destroy (mongoc_client_session_t *session);

MONGOC_EXPORT (bool)
mongoc_client_session_get_dirty (mongoc_client_session_t *session);

BSON_END_DECLS


#endif /* MONGOC_CLIENT_SESSION_H */

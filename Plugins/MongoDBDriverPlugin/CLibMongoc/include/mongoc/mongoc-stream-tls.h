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

#ifndef MONGOC_STREAM_TLS_H
#define MONGOC_STREAM_TLS_H

#include <bson/bson.h>

#include "mongoc-macros.h"
#include "mongoc-ssl.h"
#include "mongoc-stream.h"


BSON_BEGIN_DECLS

typedef struct _mongoc_stream_tls_t mongoc_stream_tls_t;

MONGOC_EXPORT (bool)
mongoc_stream_tls_handshake (
   mongoc_stream_t *stream, const char *host, int32_t timeout_msec, int *events, bson_error_t *error);
MONGOC_EXPORT (bool)
mongoc_stream_tls_handshake_block (mongoc_stream_t *stream,
                                   const char *host,
                                   int32_t timeout_msec,
                                   bson_error_t *error);
MONGOC_EXPORT (bool)
mongoc_stream_tls_do_handshake (mongoc_stream_t *stream, int32_t timeout_msec)
   BSON_GNUC_DEPRECATED_FOR (mongoc_stream_tls_handshake);
MONGOC_EXPORT (bool)
mongoc_stream_tls_check_cert (mongoc_stream_t *stream, const char *host)
   BSON_GNUC_DEPRECATED_FOR (mongoc_stream_tls_handshake);
MONGOC_EXPORT (mongoc_stream_t *)
mongoc_stream_tls_new_with_hostname (mongoc_stream_t *base_stream, const char *host, mongoc_ssl_opt_t *opt, int client)
   BSON_GNUC_WARN_UNUSED_RESULT;
MONGOC_EXPORT (mongoc_stream_t *)
mongoc_stream_tls_new (mongoc_stream_t *base_stream, mongoc_ssl_opt_t *opt, int client) BSON_GNUC_WARN_UNUSED_RESULT
   BSON_GNUC_DEPRECATED_FOR (mongoc_stream_tls_new_with_hostname);


BSON_END_DECLS


#endif /* MONGOC_STREAM_TLS_H */

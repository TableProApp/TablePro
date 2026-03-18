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

#ifndef MONGOC_STREAM_TLS_OPENSSL_H
#define MONGOC_STREAM_TLS_OPENSSL_H

#ifdef MONGOC_ENABLE_SSL_OPENSSL
#include <bson/bson.h>

#include "mongoc-macros.h"

BSON_BEGIN_DECLS

MONGOC_EXPORT (mongoc_stream_t *)
mongoc_stream_tls_openssl_new (mongoc_stream_t *base_stream, const char *host, mongoc_ssl_opt_t *opt, int client)
   BSON_GNUC_WARN_UNUSED_RESULT;

BSON_END_DECLS

#endif /* MONGOC_ENABLE_SSL_OPENSSL */
#endif /* MONGOC_STREAM_TLS_OPENSSL_H */

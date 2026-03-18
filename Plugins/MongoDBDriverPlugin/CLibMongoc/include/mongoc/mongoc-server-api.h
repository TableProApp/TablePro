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

#ifndef MONGOC_SERVER_API_H
#define MONGOC_SERVER_API_H

#include <bson/bson.h>

#include "mongoc-optional.h"
#include "mongoc-macros.h"

BSON_BEGIN_DECLS

typedef enum { MONGOC_SERVER_API_V1 } mongoc_server_api_version_t;

typedef struct _mongoc_server_api_t mongoc_server_api_t;

MONGOC_EXPORT (const char *)
mongoc_server_api_version_to_string (mongoc_server_api_version_t version);

MONGOC_EXPORT (bool)
mongoc_server_api_version_from_string (const char *version, mongoc_server_api_version_t *out);

MONGOC_EXPORT (mongoc_server_api_t *)
mongoc_server_api_new (mongoc_server_api_version_t version) BSON_GNUC_WARN_UNUSED_RESULT;

MONGOC_EXPORT (mongoc_server_api_t *)
mongoc_server_api_copy (const mongoc_server_api_t *api) BSON_GNUC_WARN_UNUSED_RESULT;

MONGOC_EXPORT (void)
mongoc_server_api_destroy (mongoc_server_api_t *api);

MONGOC_EXPORT (void)
mongoc_server_api_strict (mongoc_server_api_t *api, bool strict);

MONGOC_EXPORT (void)
mongoc_server_api_deprecation_errors (mongoc_server_api_t *api, bool deprecation_errors);

MONGOC_EXPORT (const mongoc_optional_t *)
mongoc_server_api_get_deprecation_errors (const mongoc_server_api_t *api);

MONGOC_EXPORT (const mongoc_optional_t *)
mongoc_server_api_get_strict (const mongoc_server_api_t *api);

MONGOC_EXPORT (mongoc_server_api_version_t)
mongoc_server_api_get_version (const mongoc_server_api_t *api);

BSON_END_DECLS

#endif /* MONGOC_SERVER_API_H */

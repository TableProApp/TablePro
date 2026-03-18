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

#ifndef MONGOC_TOPOLOGY_DESCRIPTION_H
#define MONGOC_TOPOLOGY_DESCRIPTION_H

#include <bson/bson.h>

#include "mongoc-macros.h"
#include "mongoc-read-prefs.h"


BSON_BEGIN_DECLS

typedef struct _mongoc_topology_description_t mongoc_topology_description_t;

MONGOC_EXPORT (void)
mongoc_topology_description_destroy (mongoc_topology_description_t *description);

MONGOC_EXPORT (mongoc_topology_description_t *)
mongoc_topology_description_new_copy (const mongoc_topology_description_t *description) BSON_GNUC_WARN_UNUSED_RESULT;

MONGOC_EXPORT (bool)
mongoc_topology_description_has_readable_server (const mongoc_topology_description_t *td,
                                                 const mongoc_read_prefs_t *prefs);

MONGOC_EXPORT (bool)
mongoc_topology_description_has_writable_server (const mongoc_topology_description_t *td);

MONGOC_EXPORT (const char *)
mongoc_topology_description_type (const mongoc_topology_description_t *td);

MONGOC_EXPORT (mongoc_server_description_t **)
mongoc_topology_description_get_servers (const mongoc_topology_description_t *td,
                                         size_t *n) BSON_GNUC_WARN_UNUSED_RESULT;

BSON_END_DECLS

#endif /* MONGOC_TOPOLOGY_DESCRIPTION_H */

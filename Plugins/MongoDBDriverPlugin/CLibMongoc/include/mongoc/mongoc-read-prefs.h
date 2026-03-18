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

#ifndef MONGOC_READ_PREFS_H
#define MONGOC_READ_PREFS_H

#include <bson/bson.h>

#include "mongoc-macros.h"
#include "mongoc-config.h"

BSON_BEGIN_DECLS


#define MONGOC_NO_MAX_STALENESS -1
#define MONGOC_SMALLEST_MAX_STALENESS_SECONDS 90

typedef struct _mongoc_read_prefs_t mongoc_read_prefs_t;


typedef enum {
   /** Represents $readPreference.mode of 'primary' */
   MONGOC_READ_PRIMARY = (1 << 0),
   /** Represents $readPreference.mode of 'secondary' */
   MONGOC_READ_SECONDARY = (1 << 1),
   /** Represents $readPreference.mode of 'primaryPreferred' */
   MONGOC_READ_PRIMARY_PREFERRED = (1 << 2) | MONGOC_READ_PRIMARY,
   /** Represents $readPreference.mode of 'secondaryPreferred' */
   MONGOC_READ_SECONDARY_PREFERRED = (1 << 2) | MONGOC_READ_SECONDARY,
   /** Represents $readPreference.mode of 'nearest' */
   MONGOC_READ_NEAREST = (1 << 3) | MONGOC_READ_SECONDARY,
} mongoc_read_mode_t;


MONGOC_EXPORT (mongoc_read_prefs_t *)
mongoc_read_prefs_new (mongoc_read_mode_t read_mode) BSON_GNUC_WARN_UNUSED_RESULT;
MONGOC_EXPORT (mongoc_read_prefs_t *)
mongoc_read_prefs_copy (const mongoc_read_prefs_t *read_prefs) BSON_GNUC_WARN_UNUSED_RESULT;
MONGOC_EXPORT (void)
mongoc_read_prefs_destroy (mongoc_read_prefs_t *read_prefs);
MONGOC_EXPORT (mongoc_read_mode_t)
mongoc_read_prefs_get_mode (const mongoc_read_prefs_t *read_prefs);
MONGOC_EXPORT (void)
mongoc_read_prefs_set_mode (mongoc_read_prefs_t *read_prefs, mongoc_read_mode_t mode);
MONGOC_EXPORT (const bson_t *)
mongoc_read_prefs_get_tags (const mongoc_read_prefs_t *read_prefs);
MONGOC_EXPORT (void)
mongoc_read_prefs_set_tags (mongoc_read_prefs_t *read_prefs, const bson_t *tags);
MONGOC_EXPORT (void)
mongoc_read_prefs_add_tag (mongoc_read_prefs_t *read_prefs, const bson_t *tag);
MONGOC_EXPORT (int64_t)
mongoc_read_prefs_get_max_staleness_seconds (const mongoc_read_prefs_t *read_prefs);
MONGOC_EXPORT (void)
mongoc_read_prefs_set_max_staleness_seconds (mongoc_read_prefs_t *read_prefs, int64_t max_staleness_seconds);
MONGOC_EXPORT (const bson_t *)
mongoc_read_prefs_get_hedge (const mongoc_read_prefs_t *read_prefs);
MONGOC_EXPORT (void)
mongoc_read_prefs_set_hedge (mongoc_read_prefs_t *read_prefs, const bson_t *hedge);
MONGOC_EXPORT (bool)
mongoc_read_prefs_is_valid (const mongoc_read_prefs_t *read_prefs);


BSON_END_DECLS


#endif /* MONGOC_READ_PREFS_H */

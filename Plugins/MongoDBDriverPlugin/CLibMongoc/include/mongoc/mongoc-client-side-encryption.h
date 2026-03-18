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

#ifndef MONGOC_CLIENT_SIDE_ENCRYPTION_H
#define MONGOC_CLIENT_SIDE_ENCRYPTION_H

#include <bson/bson.h>

/* Forward declare */
struct _mongoc_client_t;
struct _mongoc_client_pool_t;
struct _mongoc_cursor_t;

struct _mongoc_collection_t;
struct _mongoc_database_t;

#define MONGOC_AEAD_AES_256_CBC_HMAC_SHA_512_RANDOM "AEAD_AES_256_CBC_HMAC_SHA_512-Random"
#define MONGOC_AEAD_AES_256_CBC_HMAC_SHA_512_DETERMINISTIC "AEAD_AES_256_CBC_HMAC_SHA_512-Deterministic"
#define MONGOC_ENCRYPT_ALGORITHM_INDEXED "Indexed"
#define MONGOC_ENCRYPT_ALGORITHM_UNINDEXED "Unindexed"
#define MONGOC_ENCRYPT_ALGORITHM_RANGE "Range"
#define MONGOC_ENCRYPT_ALGORITHM_RANGEPREVIEW "RangePreview"

#define MONGOC_ENCRYPT_QUERY_TYPE_EQUALITY "equality"
#define MONGOC_ENCRYPT_QUERY_TYPE_RANGE "range"
#define MONGOC_ENCRYPT_QUERY_TYPE_RANGEPREVIEW "rangePreview"


BSON_BEGIN_DECLS

typedef struct _mongoc_auto_encryption_opts_t mongoc_auto_encryption_opts_t;

typedef bool (*mongoc_kms_credentials_provider_callback_fn) (void *userdata,
                                                             const bson_t *params,
                                                             bson_t *out,
                                                             bson_error_t *error);

MONGOC_EXPORT (mongoc_auto_encryption_opts_t *)
mongoc_auto_encryption_opts_new (void) BSON_GNUC_WARN_UNUSED_RESULT;

MONGOC_EXPORT (void)
mongoc_auto_encryption_opts_destroy (mongoc_auto_encryption_opts_t *opts);

MONGOC_EXPORT (void)
mongoc_auto_encryption_opts_set_keyvault_client (mongoc_auto_encryption_opts_t *opts, struct _mongoc_client_t *client);

MONGOC_EXPORT (void)
mongoc_auto_encryption_opts_set_keyvault_client_pool (mongoc_auto_encryption_opts_t *opts,
                                                      struct _mongoc_client_pool_t *pool);

MONGOC_EXPORT (void)
mongoc_auto_encryption_opts_set_keyvault_namespace (mongoc_auto_encryption_opts_t *opts,
                                                    const char *db,
                                                    const char *coll);

MONGOC_EXPORT (void)
mongoc_auto_encryption_opts_set_kms_providers (mongoc_auto_encryption_opts_t *opts, const bson_t *kms_providers);

MONGOC_EXPORT (void)
mongoc_auto_encryption_opts_set_tls_opts (mongoc_auto_encryption_opts_t *opts, const bson_t *tls_opts);

MONGOC_EXPORT (void)
mongoc_auto_encryption_opts_set_schema_map (mongoc_auto_encryption_opts_t *opts, const bson_t *schema_map);

MONGOC_EXPORT (void)
mongoc_auto_encryption_opts_set_encrypted_fields_map (mongoc_auto_encryption_opts_t *opts,
                                                      const bson_t *encrypted_fields_map);

MONGOC_EXPORT (void)
mongoc_auto_encryption_opts_set_bypass_auto_encryption (mongoc_auto_encryption_opts_t *opts,
                                                        bool bypass_auto_encryption);

MONGOC_EXPORT (void)
mongoc_auto_encryption_opts_set_bypass_query_analysis (mongoc_auto_encryption_opts_t *opts, bool bypass_query_analysis);

MONGOC_EXPORT (void)
mongoc_auto_encryption_opts_set_extra (mongoc_auto_encryption_opts_t *opts, const bson_t *extra);

MONGOC_EXPORT (void)
mongoc_auto_encryption_opts_set_kms_credential_provider_callback (mongoc_auto_encryption_opts_t *opts,
                                                                  mongoc_kms_credentials_provider_callback_fn fn,
                                                                  void *userdata);

typedef struct _mongoc_client_encryption_opts_t mongoc_client_encryption_opts_t;
typedef struct _mongoc_client_encryption_t mongoc_client_encryption_t;
typedef struct _mongoc_client_encryption_encrypt_range_opts_t mongoc_client_encryption_encrypt_range_opts_t;
typedef struct _mongoc_client_encryption_encrypt_opts_t mongoc_client_encryption_encrypt_opts_t;
typedef struct _mongoc_client_encryption_datakey_opts_t mongoc_client_encryption_datakey_opts_t;
typedef struct _mongoc_client_encryption_rewrap_many_datakey_result_t
   mongoc_client_encryption_rewrap_many_datakey_result_t;

MONGOC_EXPORT (mongoc_client_encryption_opts_t *)
mongoc_client_encryption_opts_new (void) BSON_GNUC_WARN_UNUSED_RESULT;

MONGOC_EXPORT (void)
mongoc_client_encryption_opts_destroy (mongoc_client_encryption_opts_t *opts);

MONGOC_EXPORT (void)
mongoc_client_encryption_opts_set_keyvault_client (mongoc_client_encryption_opts_t *opts,
                                                   struct _mongoc_client_t *keyvault_client);

MONGOC_EXPORT (void)
mongoc_client_encryption_opts_set_keyvault_namespace (mongoc_client_encryption_opts_t *opts,
                                                      const char *db,
                                                      const char *coll);

MONGOC_EXPORT (void)
mongoc_client_encryption_opts_set_kms_providers (mongoc_client_encryption_opts_t *opts, const bson_t *kms_providers);

MONGOC_EXPORT (void)
mongoc_client_encryption_opts_set_tls_opts (mongoc_client_encryption_opts_t *opts, const bson_t *tls_opts);

MONGOC_EXPORT (void)
mongoc_client_encryption_opts_set_kms_credential_provider_callback (mongoc_client_encryption_opts_t *opts,
                                                                    mongoc_kms_credentials_provider_callback_fn fn,
                                                                    void *userdata);

MONGOC_EXPORT (mongoc_client_encryption_rewrap_many_datakey_result_t *)
mongoc_client_encryption_rewrap_many_datakey_result_new (void) BSON_GNUC_WARN_UNUSED_RESULT;

MONGOC_EXPORT (void)
mongoc_client_encryption_rewrap_many_datakey_result_destroy (
   mongoc_client_encryption_rewrap_many_datakey_result_t *result);

MONGOC_EXPORT (const bson_t *)
mongoc_client_encryption_rewrap_many_datakey_result_get_bulk_write_result (
   mongoc_client_encryption_rewrap_many_datakey_result_t *result) BSON_GNUC_WARN_UNUSED_RESULT;

MONGOC_EXPORT (mongoc_client_encryption_t *)
mongoc_client_encryption_new (mongoc_client_encryption_opts_t *opts, bson_error_t *error) BSON_GNUC_WARN_UNUSED_RESULT;

MONGOC_EXPORT (void)
mongoc_client_encryption_destroy (mongoc_client_encryption_t *client_encryption);

MONGOC_EXPORT (bool)
mongoc_client_encryption_create_datakey (mongoc_client_encryption_t *client_encryption,
                                         const char *kms_provider,
                                         const mongoc_client_encryption_datakey_opts_t *opts,
                                         bson_value_t *keyid,
                                         bson_error_t *error);

MONGOC_EXPORT (bool)
mongoc_client_encryption_rewrap_many_datakey (mongoc_client_encryption_t *client_encryption,
                                              const bson_t *filter,
                                              const char *provider,
                                              const bson_t *master_key,
                                              mongoc_client_encryption_rewrap_many_datakey_result_t *result,
                                              bson_error_t *error);

MONGOC_EXPORT (bool)
mongoc_client_encryption_delete_key (mongoc_client_encryption_t *client_encryption,
                                     const bson_value_t *keyid,
                                     bson_t *reply,
                                     bson_error_t *error);

MONGOC_EXPORT (bool)
mongoc_client_encryption_get_key (mongoc_client_encryption_t *client_encryption,
                                  const bson_value_t *keyid,
                                  bson_t *key_doc,
                                  bson_error_t *error);

MONGOC_EXPORT (struct _mongoc_cursor_t *)
mongoc_client_encryption_get_keys (mongoc_client_encryption_t *client_encryption, bson_error_t *error);

MONGOC_EXPORT (bool)
mongoc_client_encryption_add_key_alt_name (mongoc_client_encryption_t *client_encryption,
                                           const bson_value_t *keyid,
                                           const char *keyaltname,
                                           bson_t *key_doc,
                                           bson_error_t *error);

MONGOC_EXPORT (bool)
mongoc_client_encryption_remove_key_alt_name (mongoc_client_encryption_t *client_encryption,
                                              const bson_value_t *keyid,
                                              const char *keyaltname,
                                              bson_t *key_doc,
                                              bson_error_t *error);

MONGOC_EXPORT (bool)
mongoc_client_encryption_get_key_by_alt_name (mongoc_client_encryption_t *client_encryption,
                                              const char *keyaltname,
                                              bson_t *key_doc,
                                              bson_error_t *error);

MONGOC_EXPORT (bool)
mongoc_client_encryption_encrypt (mongoc_client_encryption_t *client_encryption,
                                  const bson_value_t *value,
                                  mongoc_client_encryption_encrypt_opts_t *opts,
                                  bson_value_t *ciphertext,
                                  bson_error_t *error);

MONGOC_EXPORT (bool)
mongoc_client_encryption_encrypt_expression (mongoc_client_encryption_t *client_encryption,
                                             const bson_t *expr,
                                             mongoc_client_encryption_encrypt_opts_t *opts,
                                             bson_t *expr_out,
                                             bson_error_t *error);

MONGOC_EXPORT (bool)
mongoc_client_encryption_decrypt (mongoc_client_encryption_t *client_encryption,
                                  const bson_value_t *ciphertext,
                                  bson_value_t *value,
                                  bson_error_t *error);

MONGOC_EXPORT (mongoc_client_encryption_encrypt_opts_t *)
mongoc_client_encryption_encrypt_opts_new (void) BSON_GNUC_WARN_UNUSED_RESULT;

MONGOC_EXPORT (void)
mongoc_client_encryption_encrypt_opts_destroy (mongoc_client_encryption_encrypt_opts_t *opts);

MONGOC_EXPORT (void)
mongoc_client_encryption_encrypt_opts_set_keyid (mongoc_client_encryption_encrypt_opts_t *opts,
                                                 const bson_value_t *keyid);

MONGOC_EXPORT (void)
mongoc_client_encryption_encrypt_opts_set_keyaltname (mongoc_client_encryption_encrypt_opts_t *opts,
                                                      const char *keyaltname);

MONGOC_EXPORT (void)
mongoc_client_encryption_encrypt_opts_set_algorithm (mongoc_client_encryption_encrypt_opts_t *opts,
                                                     const char *algorithm);

MONGOC_EXPORT (void)
mongoc_client_encryption_encrypt_opts_set_contention_factor (mongoc_client_encryption_encrypt_opts_t *opts,
                                                             int64_t contention_factor);

MONGOC_EXPORT (void)
mongoc_client_encryption_encrypt_opts_set_query_type (mongoc_client_encryption_encrypt_opts_t *opts,
                                                      const char *query_type);

MONGOC_EXPORT (mongoc_client_encryption_encrypt_range_opts_t *)
mongoc_client_encryption_encrypt_range_opts_new (void);

MONGOC_EXPORT (void)
mongoc_client_encryption_encrypt_range_opts_destroy (mongoc_client_encryption_encrypt_range_opts_t *range_opts);

MONGOC_EXPORT (void)
mongoc_client_encryption_encrypt_range_opts_set_trim_factor (mongoc_client_encryption_encrypt_range_opts_t *range_opts,
                                                             int32_t trim_factor);

MONGOC_EXPORT (void)
mongoc_client_encryption_encrypt_range_opts_set_sparsity (mongoc_client_encryption_encrypt_range_opts_t *range_opts,
                                                          int64_t sparsity);

MONGOC_EXPORT (void)
mongoc_client_encryption_encrypt_range_opts_set_min (mongoc_client_encryption_encrypt_range_opts_t *range_opts,
                                                     const bson_value_t *min);

MONGOC_EXPORT (void)
mongoc_client_encryption_encrypt_range_opts_set_max (mongoc_client_encryption_encrypt_range_opts_t *range_opts,
                                                     const bson_value_t *max);

MONGOC_EXPORT (void)
mongoc_client_encryption_encrypt_range_opts_set_precision (mongoc_client_encryption_encrypt_range_opts_t *range_opts,
                                                           int32_t precision);

MONGOC_EXPORT (void)
mongoc_client_encryption_encrypt_opts_set_range_opts (mongoc_client_encryption_encrypt_opts_t *opts,
                                                      const mongoc_client_encryption_encrypt_range_opts_t *range_opts);

MONGOC_EXPORT (mongoc_client_encryption_datakey_opts_t *)
mongoc_client_encryption_datakey_opts_new (void) BSON_GNUC_WARN_UNUSED_RESULT;

MONGOC_EXPORT (void)
mongoc_client_encryption_datakey_opts_destroy (mongoc_client_encryption_datakey_opts_t *opts);

MONGOC_EXPORT (void)
mongoc_client_encryption_datakey_opts_set_masterkey (mongoc_client_encryption_datakey_opts_t *opts,
                                                     const bson_t *masterkey);

MONGOC_EXPORT (void)
mongoc_client_encryption_datakey_opts_set_keyaltnames (mongoc_client_encryption_datakey_opts_t *opts,
                                                       char **keyaltnames,
                                                       uint32_t keyaltnames_count);

MONGOC_EXPORT (void)
mongoc_client_encryption_datakey_opts_set_keymaterial (mongoc_client_encryption_datakey_opts_t *opts,
                                                       const uint8_t *data,
                                                       uint32_t len);

MONGOC_EXPORT (const char *)
mongoc_client_encryption_get_crypt_shared_version (mongoc_client_encryption_t const *enc) BSON_GNUC_WARN_UNUSED_RESULT;

MONGOC_EXPORT (struct _mongoc_collection_t *)
mongoc_client_encryption_create_encrypted_collection (mongoc_client_encryption_t *enc,
                                                      struct _mongoc_database_t *database,
                                                      const char *name,
                                                      const bson_t *in_options,
                                                      bson_t *opt_out_options,
                                                      const char *const kms_provider,
                                                      const bson_t *opt_masterkey,
                                                      bson_error_t *error) BSON_GNUC_WARN_UNUSED_RESULT;

BSON_END_DECLS

#endif /* MONGOC_CLIENT_SIDE_ENCRYPTION_H */

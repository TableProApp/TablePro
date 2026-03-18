#include "mongoc-prelude.h"

#ifndef MONGOC_SLEEP_H
#define MONGOC_SLEEP_H

#include <bson/bson.h>

#include "mongoc-macros.h"

BSON_BEGIN_DECLS

/**
 * mongoc_usleep_func_t:
 * @usec: Number of microseconds to sleep for.
 * @user_data: User data provided to mongoc_client_set_usleep_impl().
 */
typedef void (*mongoc_usleep_func_t) (int64_t usec, void *user_data);

/**
 * mongoc_client_set_usleep_impl:
 * @usleep_func: A function to perform microsecond sleep.
 *
 * Sets the function to be called to perform sleep during scanning.
 * Returns the old function.
 * If old_user_data is not NULL, *old_user_data is set to the old user_data.
 * Not thread-safe.
 * Providing a `usleep_func` that does not sleep (e.g. coroutine suspension) is
 * not supported. Doing so is at the user's own risk.
 */
MONGOC_EXPORT (void)
mongoc_client_set_usleep_impl (mongoc_client_t *client, mongoc_usleep_func_t usleep_func, void *user_data);

MONGOC_EXPORT (void)
mongoc_usleep_default_impl (int64_t usec, void *user_data);

BSON_END_DECLS

#endif /* MONGOC_SLEEP_H */

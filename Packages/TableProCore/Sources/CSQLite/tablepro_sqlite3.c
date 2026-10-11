#include "tablepro_sqlite3.h"

int tablepro_sqlite3_set_extension_loading(sqlite3 *db, int enabled, int *isEnabled) {
    return sqlite3_db_config(db, SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, enabled ? 1 : 0, isEnabled);
}

#ifndef TABLEPRO_SQLITE3_H
#define TABLEPRO_SQLITE3_H

#include "sqlite3.h"

int tablepro_sqlite3_set_extension_loading(sqlite3 *db, int enabled, int *isEnabled);

#endif

//
//  CMariaDB.h
//  TablePro
//
//  C bridging header for libmariadb (MariaDB Connector/C)
//  Install: brew install mariadb-connector-c
//

#ifndef CMariaDB_h
#define CMariaDB_h

#include "include/mysql.h"
#include "include/ma_pvio.h"
#include "include/mysqld_error.h"

static inline my_bool tablepro_mysql_set_io_timeout(MYSQL *mysql, unsigned int seconds) {
    if (mysql == NULL || mysql->net.pvio == NULL) {
        return 1;
    }
    mysql->options.read_timeout = seconds;
    mysql->options.write_timeout = seconds;
    my_bool read_result = ma_pvio_set_timeout(mysql->net.pvio, PVIO_READ_TIMEOUT, (int)seconds);
    my_bool write_result = ma_pvio_set_timeout(mysql->net.pvio, PVIO_WRITE_TIMEOUT, (int)seconds);
    return read_result || write_result;
}

#endif /* CMariaDB_h */

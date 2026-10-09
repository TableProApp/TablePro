// Reads fake_tds.py's answers through the stub headers the driver compiles against, the way
// FreeTDSConnection does, and prints one line per fact check-freetds-cell-reading.sh compares.
//
// Usage: reader <freetds.conf> <server section>

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sybfront.h>
#include <sybdb.h>

static int on_error(DBPROCESS *proc, int severity, int dberr, int oserr, const char *text, const char *ostext)
{
    fprintf(stderr, "db-lib %d: %s\n", dberr, text ? text : "");
    return INT_CANCEL;
}

static int on_message(DBPROCESS *proc, DBINT number, int state, int severity, char *text, char *server,
                      char *procedure, int line)
{
    fprintf(stderr, "server %d: %s\n", (int) number, text ? text : "");
    return 0;
}

static int first_row(DBPROCESS *proc, const char *batch)
{
    if (dbcmd(proc, batch) != SUCCEED || dbsqlexec(proc) != SUCCEED || dbresults(proc) != SUCCEED) {
        printf("%s: no result\n", batch);
        return 0;
    }
    RETCODE row = dbnextrow(proc);
    if (row == NO_MORE_ROWS || row == FAIL) {
        printf("%s: no row\n", batch);
        return 0;
    }
    return 1;
}

static void finish(DBPROCESS *proc)
{
    dbcanquery(proc);
    while (dbresults(proc) == SUCCEED)
        dbcanquery(proc);
}

static void null_vs_empty(DBPROCESS *proc)
{
    if (first_row(proc, "null-vs-empty")) {
        for (int c = 1; c <= dbnumcols(proc); c++)
            printf("cell %s: dbdatlen=%d dbdata=%s\n", dbcolname(proc, c), (int) dbdatlen(proc, c),
                   dbdata(proc, c) ? "set" : "NULL");
    }
    finish(proc);
}

static void datetimeoffsets(DBPROCESS *proc)
{
    if (first_row(proc, "datetimeoffset")) {
        for (int c = 1; c <= dbnumcols(proc); c++) {
            int type = dbcoltype(proc, c);
            BYTE *data = dbdata(proc, c);
            BYTE text[256] = {0};
            DBINT length = dbconvert(proc, type, data, dbdatlen(proc, c), SYBCHAR, text, sizeof text);
            DBDATEREC2 rec;
            memset(&rec, 0, sizeof rec);
            RETCODE cracked = dbanydatecrack(proc, &rec, type, data);
            printf("dto %s: type=%d dbconvert='%.*s'\n", dbcolname(proc, c), type, length > 0 ? (int) length : 0, text);
            printf("dto %s: dbanydatecrack=%s %04d-%02d-%02d %02d:%02d:%02d.%09d tzone=%d\n", dbcolname(proc, c),
                   cracked == SUCCEED ? "SUCCEED" : "FAIL", rec.year, rec.month, rec.day, rec.hour, rec.minute,
                   rec.second, rec.nanosecond, rec.tzone);
        }
    }
    finish(proc);
}

static void row_count(DBPROCESS *proc, const char *batch)
{
    printf("%s: dbcount", batch);
    if (dbcmd(proc, batch) == SUCCEED && dbsqlexec(proc) == SUCCEED) {
        while (dbresults(proc) == SUCCEED) {
            printf(" %d", (int) dbcount(proc));
            dbcanquery(proc);
        }
    }
    putchar('\n');
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: %s <freetds.conf> <server section>\n", argv[0]);
        return 2;
    }
    // The conf's connect timeout bounds only the login; db-lib waits on a query forever.
    alarm(30);
    dbinit();
    dberrhandle(on_error);
    dbmsghandle(on_message);
    // The conf names the server, so libtds stops there and never reads the user's ~/.freetds.conf.
    dbsetifile(argv[1]);
    LOGINREC *login = dblogin();
    DBSETLUSER(login, "probe");
    DBSETLPWD(login, "probe");
    dbsetlname(login, "UTF-8", DBSETCHARSET);
    dbsetlversion(login, DBVERSION_74);
    DBPROCESS *proc = dbopen(login, argv[2]);
    if (!proc) {
        fprintf(stderr, "could not log in to %s\n", argv[2]);
        return 2;
    }
    null_vs_empty(proc);
    datetimeoffsets(proc);
    row_count(proc, "count set-prefix");
    row_count(proc, "count nocount-on");
    dbclose(proc);
    dbexit();
    return 0;
}

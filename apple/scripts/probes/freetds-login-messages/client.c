// Prints whether db-lib hands the message and error handlers a DBPROCESS during a refused login.
#include <stdio.h>
#include <stdlib.h>
#include <sybfront.h>
#include <sybdb.h>

static int on_error(DBPROCESS *proc, int severity, int dberr, int oserr, char *text, char *ostext)
{
    printf("err proc=%s dberr=%d: %s\n", proc ? "SET" : "NULL", dberr, text ? text : "");
    return INT_CANCEL;
}

static int on_message(DBPROCESS *proc, DBINT number, int state, int severity, char *text, char *server,
                      char *procedure, int line)
{
    printf("msg proc=%s %d sev %d: %s\n", proc ? "SET" : "NULL", (int) number, severity, text ? text : "");
    return 0;
}

int main(int argc, char **argv)
{
    dbinit();
    dbsetifile(argv[1]);
    dberrhandle((EHANDLEFUNC) on_error);
    dbmsghandle((MHANDLEFUNC) on_message);
    LOGINREC *login = dblogin();
    DBSETLUSER(login, "v-token-ro-1");
    DBSETLPWD(login, "secret");
    dbsetlname(login, "inventory", DBSETDBNAME);
    DBPROCESS *proc = dbopen(login, argv[2]);
    printf("dbopen=%s\n", proc ? "SET" : "NULL");
    return 0;
}

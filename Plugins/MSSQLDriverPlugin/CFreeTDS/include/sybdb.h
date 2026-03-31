//
//  sybdb.h - FreeTDS db-lib stub header
//  Swift-compatible bridge: real libsybdb.a provides the implementation.
//
#ifndef _SYBDB_H_
#define _SYBDB_H_

#include "sybfront.h"

// Opaque connection and login types.
// Placeholder bodies allow Swift to use UnsafeMutablePointer<DBPROCESS>.
// The real FreeTDS structs are internal; we never access fields from Swift.
struct dbprocess { char _placeholder; };
typedef struct dbprocess DBPROCESS;
struct loginrec { char _placeholder; };
typedef struct loginrec LOGINREC;

// Column type constants (TDS wire types)
#define SYBCHAR         47
#define SYBVARCHAR      39
#define SYBNCHAR        175
#define SYBNVARCHAR     103
#define SYBTEXT         35
#define SYBNTEXT        99
#define SYBINT1         48
#define SYBINT2         52
#define SYBINT4         56
#define SYBINT8         127
#define SYBINTN         38
#define SYBFLT8         62
#define SYBREAL         59
#define SYBFLTN         109
#define SYBDECIMAL      106
#define SYBNUMERIC      108
#define SYBMONEY        60
#define SYBMONEY4       122
#define SYBMONEYN       110
#define SYBBIT          50
#define SYBBINARY       45
#define SYBVARBINARY    37
#define SYBIMAGE        34
#define SYBDATETIME     61
#define SYBDATETIME4    58
#define SYBDATETIMN     111
#define SYBUNIQUE       36

// Login property constants for dbsetlname() — values verified against FreeTDS 1.4 sybdb.h
#define DBSETHOST   1
#define DBSETUSER   2
#define DBSETPWD    3
#define DBSETAPP    5   // 4 is unused; real FreeTDS DBSETAPP = 5
#define DBSETCHARSET 7  // Client charset for dbsetlname() — controls string encoding

// Convenience macros (match FreeTDS sybdb.h)
#define DBSETLHOST(x, y)    dbsetlname((x), (y), DBSETHOST)
#define DBSETLUSER(x, y)    dbsetlname((x), (y), DBSETUSER)
#define DBSETLPWD(x, y)     dbsetlname((x), (y), DBSETPWD)
#define DBSETLAPP(x, y)     dbsetlname((x), (y), DBSETAPP)

// TDS version constants — verified against FreeTDS 1.4 sybdb.h
#define DBVERSION_74    8   // TDS 7.4 (SQL Server 2012+)

// Encryption
#define ENCRYPT_OFF     0

// Error handler return codes
#define INT_CANCEL  2
#define INT_CONTINUE 1
#define INT_EXIT    4

// Error handler function types
typedef int (*EHANDLEFUNC)(DBPROCESS *dbproc, int severity, int dberr, int oserr,
                           const char *dberrstr, const char *oserrstr);
typedef int (*MHANDLEFUNC)(DBPROCESS *dbproc, DBINT msgno, int msgstate, int severity,
                           char *msgtext, char *srvname, char *proc, int line);

// Core db-lib API
extern RETCODE dbinit(void);
extern void dbexit(void);

extern LOGINREC *dblogin(void);
extern void dbloginfree(LOGINREC *loginrec);
extern RETCODE dbsetlname(LOGINREC *loginrec, const char *value, int which);
extern RETCODE dbsetlversion(LOGINREC *loginrec, BYTE version);

// tdsdbopen is the real symbol; dbopen is a macro wrapper in the real header
// (msdblib=1 enables MS SQL Server behavior — required for SQL Server connections)
// Swift cannot expand C macros, so we expose a static inline function instead.
extern DBPROCESS *tdsdbopen(LOGINREC *loginrec, const char *servername, int msdblib);
static inline DBPROCESS *dbopen(LOGINREC *loginrec, const char *servername) {
    return tdsdbopen(loginrec, servername, 1);
}
extern RETCODE dbclose(DBPROCESS *dbproc);
extern RETCODE dbuse(DBPROCESS *dbproc, const char *name);

extern RETCODE dbcmd(DBPROCESS *dbproc, const char *cmdstring);
extern RETCODE dbsqlexec(DBPROCESS *dbproc);
extern RETCODE dbresults(DBPROCESS *dbproc);
extern RETCODE dbnextrow(DBPROCESS *dbproc);

extern int dbnumcols(DBPROCESS *dbproc);
extern char *dbcolname(DBPROCESS *dbproc, int colnum);
extern int dbcoltype(DBPROCESS *dbproc, int colnum);
extern BYTE *dbdata(DBPROCESS *dbproc, int colnum);
extern DBINT dbdatlen(DBPROCESS *dbproc, int colnum);

extern RETCODE dbcancel(DBPROCESS *dbproc);
extern RETCODE dbcanquery(DBPROCESS *dbproc);

// Type conversion — converts a column value to a different TDS type (e.g. to SYBCHAR for display)
extern DBINT dbconvert(DBPROCESS *dbproc, int srctype, const BYTE *src, DBINT srclen,
                       int desttype, BYTE *dest, DBINT destlen);

extern EHANDLEFUNC dberrhandle(EHANDLEFUNC handler);
extern MHANDLEFUNC dbmsghandle(MHANDLEFUNC handler);

extern char *dbversion(void);

#endif /* _SYBDB_H_ */

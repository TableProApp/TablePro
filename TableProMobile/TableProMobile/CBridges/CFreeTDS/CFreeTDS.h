#ifndef CFreeTDS_h
#define CFreeTDS_h

#include <sybfront.h>
#include <sybdb.h>

// The iOS xcframework ships a hand-trimmed sybdb.h, and it is missing this one declaration that the
// macOS bridge has. `_dbcount` is in libsybdb_ios-*.a either way (checked with nm), so declaring it
// here is enough; without it FreeTDSConnection.swift, which both platforms compile, does not build
// for iOS.
extern DBINT dbcount(DBPROCESS *dbproc);

// Missing from the same header, and in the library the same way. FreeTDSConnection.swift names the freetds.conf that
// carries every connection's encryption level with it, because dbsetlname has no field for one.
extern void dbsetifile(char *filename);

// The interrupt handler a Stop reaches the reading thread through, missing from the trimmed header in the same way.
// `_dbsetinterrupt` is in libsybdb_ios-*.a (checked with nm). Values match FreeTDS 1.4.22 sybdb.h.
#define INT_TIMEOUT 3
#define SYBETIME    20003
typedef int (*DB_DBCHKINTR_FUNC)(void *dbproc);
typedef int (*DB_DBHNDLINTR_FUNC)(void *dbproc);
extern void dbsetinterrupt(DBPROCESS *dbproc, DB_DBCHKINTR_FUNC chkintr, DB_DBHNDLINTR_FUNC hndlintr);

#endif

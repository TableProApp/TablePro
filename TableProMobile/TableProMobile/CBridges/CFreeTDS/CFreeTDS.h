#ifndef CFreeTDS_h
#define CFreeTDS_h

#include <sybfront.h>
#include <sybdb.h>

// The iOS xcframework ships a hand-trimmed sybdb.h, and it is missing this one declaration that the
// macOS bridge has. `_dbcount` is in libsybdb_ios-*.a either way (checked with nm), so declaring it
// here is enough; without it FreeTDSConnection.swift, which both platforms compile, does not build
// for iOS.
extern DBINT dbcount(DBPROCESS *dbproc);

#endif

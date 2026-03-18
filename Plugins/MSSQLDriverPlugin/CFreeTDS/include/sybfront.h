//
//  sybfront.h - FreeTDS sybfront stub header
//  Minimal types needed by sybdb.h
//
#ifndef _SYBFRONT_H_
#define _SYBFRONT_H_

#include <stdint.h>

typedef unsigned char BYTE;
typedef int32_t       DBINT;
typedef unsigned char DBBOOL;

#define SUCCEED  1
#define FAIL     0

#define NO_MORE_RESULTS  2
#define NO_MORE_ROWS    -2

typedef int RETCODE;

#endif /* _SYBFRONT_H_ */

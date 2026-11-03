// TablePro driver ABI 1.0 (core/docs/decisions/0004-driver-plugin-abi.md).
// src/ffi.rs mirrors this file; src/proto.rs holds the request and response messages.
#ifndef TABLEPRO_DRIVER_H
#define TABLEPRO_DRIVER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TP_DRIVER_MAGIC 0x54504456u
#define TP_ABI_MAJOR 1
#define TP_ABI_MINOR 0

enum {
    TP_OK = 0,
    TP_ERR_VERSION = 1,
    TP_ERR_BAD_REQUEST = 2,
    TP_ERR_PANIC = 3,
    TP_ERR_CANCELLED = 4,
    TP_ERR_DRIVER = 5,
    TP_ERR_UNSUPPORTED = 6,
    TP_ERR_SHUT_DOWN = 7,
    TP_ERR_UNKNOWN_CALL = 8,
};

enum { TP_LOG_ERROR = 1, TP_LOG_WARN = 2, TP_LOG_INFO = 3, TP_LOG_DEBUG = 4 };

// Fields up to driver_version keep their offsets in every major version, so a host reads them from a driver
// built for any major and refuses it before running any of its code.
typedef struct TpDescriptor {
    uint32_t magic;
    uint32_t size;
    uint16_t abi_major;
    uint16_t abi_minor;
    uint8_t panic_unwind;
    uint8_t reserved[7];
    const char *driver_id;
    const char *driver_version;
} TpDescriptor;

typedef struct TpBytes {
    const uint8_t *ptr;
    size_t len;
} TpBytes;

typedef struct TpErrorBuf {
    uint8_t *ptr;
    size_t cap;
    size_t len;
} TpErrorBuf;

// API tables start with their byte size, so a later minor version can append fields.
typedef struct TpHostApi {
    uint32_t size;
    uint16_t abi_major;
    uint16_t abi_minor;
    void *ctx;
    void (*log)(void *ctx, int32_t level, TpBytes message);
} TpHostApi;

struct ArrowSchema;
struct ArrowArray;

// Arrow C Data Interface. The host moves both structs out during the completion, leaving release == NULL behind,
// and releases them later, which runs the driver's own release callback.
typedef struct TpArrowBatch {
    struct ArrowSchema *schema;
    struct ArrowArray *array;
} TpArrowBatch;

// Runs exactly once per accepted call, on any thread, possibly before call() returns. response and rows are
// valid only while it runs. It must not unwind.
typedef void (*TpCompletionFn)(void *ctx, uint64_t call_id, int32_t status, TpBytes response, TpArrowBatch *rows);

typedef struct TpDriverApi {
    uint32_t size;
    uint16_t abi_major;
    uint16_t abi_minor;
    void *instance;
    // request is a protobuf tablepro.driver.v1.Request. TP_OK means one completion follows; any other status
    // means none does.
    int32_t (*call)(void *instance, uint64_t call_id, TpBytes request, TpCompletionFn done, void *done_ctx);
    int32_t (*cancel)(void *instance, uint64_t call_id);
    // Cancels every call, waits for their completions, joins the driver's threads and frees the instance.
    // Returns 0 when no driver thread is left. The image stays mapped: a driver is never unloaded.
    int32_t (*shutdown)(void *instance, uint32_t timeout_ms);
} TpDriverApi;

extern const TpDescriptor tablepro_driver_descriptor;

// out_size is the caller's writable capacity. The driver writes only the negotiated minor's table prefix,
// sets out->size to the bytes it wrote, and leaves any trailing bytes untouched. A short buffer is rejected
// before creating an instance. ABI 1.0 requires sizeof(TpDriverApi); future minors retain that prefix.
int32_t tablepro_driver_open(const TpHostApi *host, TpDriverApi *out, size_t out_size, TpErrorBuf *error);

#ifdef __cplusplus
}
#endif

#endif

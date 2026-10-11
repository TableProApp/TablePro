#ifndef OPENSSL_TLS_CLIENT_H
#define OPENSSL_TLS_CLIENT_H

typedef struct ssl_st SSL;
typedef struct ssl_ctx_st SSL_CTX;
typedef struct ssl_method_st SSL_METHOD;
typedef struct x509_store_ctx_st X509_STORE_CTX;
typedef int (*SSL_verify_cb)(int preverify_ok, X509_STORE_CTX *x509_ctx);

#define SSL_FILETYPE_PEM 1
#define SSL_CTRL_SET_TLSEXT_HOSTNAME 55
#define SSL_CTRL_SET_MIN_PROTO_VERSION 123
#define TLSEXT_NAMETYPE_host_name 0
#define TLS1_2_VERSION 0x0303
#define X509_V_ERR_HOSTNAME_MISMATCH 62
#define X509_V_ERR_IP_ADDRESS_MISMATCH 64

const SSL_METHOD *TLS_client_method(void);
SSL_CTX *SSL_CTX_new(const SSL_METHOD *meth);
void SSL_CTX_free(SSL_CTX *ctx);
long SSL_CTX_ctrl(SSL_CTX *ctx, int cmd, long larg, void *parg);
void SSL_CTX_set_verify(SSL_CTX *ctx, int mode, SSL_verify_cb callback);
int SSL_CTX_load_verify_locations(SSL_CTX *ctx, const char *CAfile, const char *CApath);
int SSL_CTX_set_default_verify_paths(SSL_CTX *ctx);
int SSL_CTX_use_certificate_chain_file(SSL_CTX *ctx, const char *file);
int SSL_CTX_use_PrivateKey_file(SSL_CTX *ctx, const char *file, int type);
SSL *SSL_new(SSL_CTX *ctx);
void SSL_free(SSL *ssl);
long SSL_ctrl(SSL *ssl, int cmd, long larg, void *parg);
int SSL_set1_host(SSL *s, const char *hostname);
long SSL_get_verify_result(const SSL *ssl);
const char *X509_verify_cert_error_string(long n);

#endif

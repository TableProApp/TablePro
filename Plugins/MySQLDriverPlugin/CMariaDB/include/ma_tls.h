#ifndef _ma_tls_h_
#define _ma_tls_h_

#include <ma_hash.h>

enum enum_pvio_tls_type {
  SSL_TYPE_DEFAULT=0,
#ifdef _WIN32
  SSL_TYPE_SCHANNEL,
#endif
  SSL_TYPE_OPENSSL,
  SSL_TYPE_GNUTLS
};

#define PROTOCOL_SSLV3    0
#define PROTOCOL_TLS_1_0  1
#define PROTOCOL_TLS_1_1  2
#define PROTOCOL_TLS_1_2  3
#define PROTOCOL_TLS_1_3  4
#define PROTOCOL_UNKNOWN  5
#define PROTOCOL_MAX PROTOCOL_TLS_1_3

#define TLS_VERSION_LENGTH 64

#define have_fingerprint(m) \
((m)->options.extension) && \
(((m)->options.extension->tls_fp && (m)->options.extension->tls_fp[0]) ||\
((m)->options.extension->tls_fp_list && (m)->options.extension->tls_fp_list[0]))

extern char tls_library_version[TLS_VERSION_LENGTH];

typedef struct st_ma_pvio_tls {
  void *data;
  MARIADB_PVIO *pvio;
  void *ssl;
  MARIADB_X509_INFO cert_info;
} MARIADB_TLS;

/* Function prototypes */

/* ma_tls_start
   initializes the ssl library
   Parameter:
     errmsg      pointer to error message buffer
     errmsg_len  length of error message buffer
   Returns:
     0           success
     1           if an error occurred
   Notes:
     On success the global variable ma_tls_initialized will be set to 1
*/
int ma_tls_start(char *errmsg, size_t errmsg_len);

/* ma_tls_end
   unloads/deinitializes ssl library and unsets global variable
   ma_tls_initialized
*/
void ma_tls_end(void);

/* ma_tls_init
   creates a new SSL structure for a SSL connection and loads
   client certificates

   Parameters:
     MYSQL        a mysql structure
   Returns:
     void *       a pointer to internal SSL structure
*/
void * ma_tls_init(MYSQL *mysql);

/* ma_tls_connect
   performs SSL handshake
   Parameters:
     MARIADB_TLS   MariaDB SSL container
   Returns:
     0             success
     1             error
*/
my_bool ma_tls_connect(MARIADB_TLS *ctls);

/* ma_tls_read
   reads up to length bytes from socket
   Parameters:
     ctls         MariaDB SSL container
     buffer       read buffer
     length       buffer length
   Returns:
     0-n          bytes read
     -1           if an error occurred
*/
ssize_t ma_tls_read(MARIADB_TLS *ctls, const uchar* buffer, size_t length);

/* ma_tls_write
   write buffer to socket
   Parameters:
     ctls         MariaDB SSL container
     buffer       write buffer
     length       buffer length
   Returns:
     0-n          bytes written
     -1           if an error occurred
*/
ssize_t ma_tls_write(MARIADB_TLS *ctls, const uchar* buffer, size_t length);

/* ma_tls_close
   closes SSL connection and frees SSL structure which was previously
   created by ma_tls_init call
   Parameters:
     MARIADB_TLS  MariaDB SSL container
   Returns:
     0            success
     1            error
*/
my_bool ma_tls_close(MARIADB_TLS *ctls);

/* ma_tls_verify_server_cert
   validation check of server certificate
   Parameter:
     MARIADB_TLS  MariaDB SSL container
     flags        verification flags
   Returns:
     0            success
     1            error
*/
int ma_tls_verify_server_cert(MARIADB_TLS *ctls, unsigned int flags);

/* ma_tls_get_cipher
   returns cipher for current ssl connection
   Parameter:
     MARIADB_TLS  MariaDB SSL container
   Returns: 
     cipher in use or
     NULL on error
*/
const char *ma_tls_get_cipher(MARIADB_TLS *ssl);

/* ma_tls_get_finger_print
   returns SHA1 finger print of server certificate
   Parameter:
     MARIADB_TLS  MariaDB SSL container
     hash_type    hash_type as defined in ma_hash.h
     fp           buffer for fingerprint
     fp_len       buffer length

   Returns:
     actual size of finger print
*/
unsigned int ma_tls_get_finger_print(MARIADB_TLS *ctls, uint hash_type, char *fp, unsigned int fp_len);

/* ma_tls_get_protocol_version 
   returns protocol version number in use
   Parameter:
     MARIADB_TLS    MariaDB SSL container
   Returns:
     protocol number
*/
int ma_tls_get_protocol_version(MARIADB_TLS *ctls);
const char *ma_pvio_tls_get_protocol_version(MARIADB_TLS *ctls);
int ma_pvio_tls_get_protocol_version_id(MARIADB_TLS *ctls);
unsigned int ma_tls_get_peer_cert_info(MARIADB_TLS *ctls, unsigned int size);
void ma_tls_set_connection(MYSQL *mysql);

/* Function prototypes */
MARIADB_TLS *ma_pvio_tls_init(MYSQL *mysql);
my_bool ma_pvio_tls_connect(MARIADB_TLS *ctls);
ssize_t ma_pvio_tls_read(MARIADB_TLS *ctls, const uchar *buffer, size_t length);
ssize_t ma_pvio_tls_write(MARIADB_TLS *ctls, const uchar *buffer, size_t length);
my_bool ma_pvio_tls_close(MARIADB_TLS *ctls);
int ma_pvio_tls_verify_server_cert(MARIADB_TLS *ctls, unsigned int flags);
const char *ma_pvio_tls_cipher(MARIADB_TLS *ctls);
my_bool ma_pvio_tls_check_fp(MARIADB_TLS *ctls, const char *fp, const char *fp_list);
my_bool ma_pvio_start_ssl(MARIADB_PVIO *pvio);
void ma_pvio_tls_set_connection(MYSQL *mysql);
void ma_pvio_tls_end();
unsigned int ma_pvio_tls_get_peer_cert_info(MARIADB_TLS *ctls, unsigned int size);

#endif /* _ma_tls_h_ */

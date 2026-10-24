FROM mysql:8.4

COPY materials/server.crt /certs/server.crt
COPY materials/server.key /certs/server.key
COPY materials/ca.crt /certs/ca.crt
COPY mysql-mtls/require-client-cert.sql /docker-entrypoint-initdb.d/10-require-client-cert.sql

RUN chown -R mysql:mysql /certs /docker-entrypoint-initdb.d/10-require-client-cert.sql \
    && chmod 600 /certs/server.key \
    && chmod 644 /certs/server.crt /certs/ca.crt /docker-entrypoint-initdb.d/10-require-client-cert.sql

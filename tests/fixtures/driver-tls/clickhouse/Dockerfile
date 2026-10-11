FROM clickhouse/clickhouse-server:24.8-alpine

COPY materials/server.crt /certs/server.crt
COPY materials/server.key /certs/server.key
COPY materials/ca.crt /certs/ca.crt
COPY clickhouse/tls.xml /etc/clickhouse-server/config.d/tls.xml

RUN chown -R clickhouse:clickhouse /certs \
    && chmod 600 /certs/server.key \
    && chmod 644 /certs/server.crt /certs/ca.crt

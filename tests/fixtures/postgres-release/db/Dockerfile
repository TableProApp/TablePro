FROM postgres:16-alpine

COPY materials/server.crt /certs/server.crt
COPY materials/server.key /certs/server.key
COPY materials/ca.crt /certs/ca.crt
COPY db/pg_hba.conf /certs/pg_hba.conf

RUN chown -R postgres:postgres /certs \
    && chmod 600 /certs/server.key \
    && chmod 644 /certs/server.crt /certs/ca.crt

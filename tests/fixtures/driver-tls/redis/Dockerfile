FROM redis:7-alpine

COPY materials/server.crt /certs/server.crt
COPY materials/server.key /certs/server.key
COPY materials/ca.crt /certs/ca.crt

RUN chown -R redis:redis /certs \
    && chmod 600 /certs/server.key \
    && chmod 644 /certs/server.crt /certs/ca.crt

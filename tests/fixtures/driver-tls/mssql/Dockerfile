FROM mcr.microsoft.com/mssql/server:2022-latest

USER root
COPY materials/server.crt /certs/server.crt
COPY materials/server.key /certs/server.key
COPY mssql/entrypoint.sh /fixture/entrypoint.sh
COPY mssql/setup.sql /fixture/setup.sql

ARG TLS_ENABLED=0

RUN chown -R mssql:root /certs /fixture \
    && chmod 400 /certs/server.key \
    && chmod 444 /certs/server.crt \
    && chmod 500 /fixture/entrypoint.sh \
    && if [ "$TLS_ENABLED" = "1" ]; then \
      /opt/mssql/bin/mssql-conf set network.tlscert /certs/server.crt \
      && /opt/mssql/bin/mssql-conf set network.tlskey /certs/server.key \
      && /opt/mssql/bin/mssql-conf set network.forceencryption 1; \
    fi

USER mssql
ENTRYPOINT ["/fixture/entrypoint.sh"]

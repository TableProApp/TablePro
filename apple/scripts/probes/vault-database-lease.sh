#!/bin/bash
# Starts a Vault dev server and Postgres in Docker, issues a database lease and prints the
# HTTP API replies TablePro parses: creds, lease renew (including the max TTL cap), revoke,
# token lookup-self and AppRole login. Leaves both containers running for a manual connect;
# remove them with: docker rm -f tp-vault-probe tp-vault-pg && docker network rm tp-vault-probe
set -euo pipefail

NET=tp-vault-probe
ROOT=root-token
VAULT_PORT=${VAULT_PORT:-18200}
PG_PORT=${PG_PORT:-15432}
ADDR="http://127.0.0.1:$VAULT_PORT"

docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
docker rm -f tp-vault-probe tp-vault-pg >/dev/null 2>&1 || true
docker run -d --name tp-vault-pg --network "$NET" -p "$PG_PORT:5432" \
    -e POSTGRES_PASSWORD=rootpw postgres:16-alpine >/dev/null
docker run -d --name tp-vault-probe --network "$NET" -p "$VAULT_PORT:8200" --cap-add IPC_LOCK \
    -e VAULT_DEV_ROOT_TOKEN_ID="$ROOT" -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 hashicorp/vault:1.18 >/dev/null

for _ in $(seq 1 60); do
    curl -sf "$ADDR/v1/sys/health" >/dev/null 2>&1 && docker exec tp-vault-pg pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 1
done

api() { curl -s -H "X-Vault-Token: ${TOKEN:-$ROOT}" -H "X-Vault-Request: true" "$@"; }

api -X POST -d '{"type":"database"}' "$ADDR/v1/sys/mounts/database" >/dev/null
api -X POST -d '{"plugin_name":"postgresql-database-plugin","allowed_roles":"readonly","connection_url":"postgresql://{{username}}:{{password}}@tp-vault-pg:5432/postgres?sslmode=disable","username":"postgres","password":"rootpw"}' \
    "$ADDR/v1/database/config/pg" >/dev/null
api -X POST -d '{"db_name":"pg","default_ttl":"60s","max_ttl":"150s","creation_statements":["CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '"'"'{{password}}'"'"' VALID UNTIL '"'"'{{expiration}}'"'"'; GRANT pg_read_all_data TO \"{{name}}\";"],"revocation_statements":["SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '"'"'{{name}}'"'"';","DROP ROLE IF EXISTS \"{{name}}\";"]}' \
    "$ADDR/v1/database/roles/readonly" >/dev/null

echo "== GET database/creds/readonly"
CREDS=$(api "$ADDR/v1/database/creds/readonly")
echo "$CREDS" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["data"]["password"]="<redacted>"; print(json.dumps({k:d[k] for k in ("lease_id","lease_duration","renewable","data")}))'
LEASE=$(echo "$CREDS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lease_id"])')

echo "== PUT sys/leases/renew increment=60 every 40 s, default_ttl 60 s, max_ttl 150 s"
for _ in 1 2 3 4; do
    api -X PUT -d "{\"lease_id\":\"$LEASE\",\"increment\":60}" "$ADDR/v1/sys/leases/renew" \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("lease_duration"), d.get("errors"))'
    sleep 40
done

echo "== PUT sys/leases/revoke"
api -o /dev/null -w "status %{http_code}\n" -X PUT -d "{\"lease_id\":\"$LEASE\"}" "$ADDR/v1/sys/leases/revoke"
echo "== PUT sys/leases/renew on the revoked lease"
api -w "\nstatus %{http_code}\n" -X PUT -d "{\"lease_id\":\"$LEASE\",\"increment\":60}" "$ADDR/v1/sys/leases/renew"

echo "== GET auth/token/lookup-self (root)"
api "$ADDR/v1/auth/token/lookup-self" | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print({k:d.get(k) for k in ("ttl","renewable","expire_time")})'
echo "== GET auth/token/lookup-self (bad token)"
TOKEN=nope api -w "\nstatus %{http_code}\n" "$ADDR/v1/auth/token/lookup-self"

api -X POST -d '{"type":"approle"}' "$ADDR/v1/sys/auth/approle" >/dev/null
api -X PUT -d '{"policy":"path \"database/creds/readonly\" { capabilities = [\"read\"] }\npath \"sys/leases/renew\" { capabilities = [\"update\"] }\npath \"sys/leases/revoke\" { capabilities = [\"update\"] }"}' \
    "$ADDR/v1/sys/policies/acl/db-reader" >/dev/null
api -X POST -d '{"token_policies":"db-reader","token_ttl":"120s","token_max_ttl":"600s"}' "$ADDR/v1/auth/approle/role/tablepro" >/dev/null
ROLE_ID=$(api "$ADDR/v1/auth/approle/role/tablepro/role-id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["role_id"])')
SECRET_ID=$(api -X POST "$ADDR/v1/auth/approle/role/tablepro/secret-id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["secret_id"])')
echo "== POST auth/approle/login"
LOGIN=$(api -X POST -d "{\"role_id\":\"$ROLE_ID\",\"secret_id\":\"$SECRET_ID\"}" "$ADDR/v1/auth/approle/login")
echo "$LOGIN" | python3 -c 'import json,sys; a=json.load(sys.stdin)["auth"]; print({k:a.get(k) for k in ("lease_duration","renewable")})'
echo "== POST auth/approle/login (wrong secret id)"
api -w "\nstatus %{http_code}\n" -X POST -d "{\"role_id\":\"$ROLE_ID\",\"secret_id\":\"wrong\"}" "$ADDR/v1/auth/approle/login"
APPROLE_TOKEN=$(echo "$LOGIN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["auth"]["client_token"])')
echo "== POST auth/token/renew-self (AppRole token)"
TOKEN=$APPROLE_TOKEN api -X POST -d '{"increment":"120s"}' "$ADDR/v1/auth/token/renew-self" | python3 -c 'import json,sys; a=json.load(sys.stdin)["auth"]; print({k:a.get(k) for k in ("lease_duration","renewable")})'
echo "== GET database/creds/readonly with a token lacking the policy"
WEAK=$(api -X POST -d '{"policies":["default"],"ttl":"60s"}' "$ADDR/v1/auth/token/create" | python3 -c 'import json,sys; print(json.load(sys.stdin)["auth"]["client_token"])')
TOKEN=$WEAK api -w "\nstatus %{http_code}\n" "$ADDR/v1/database/creds/readonly"
echo "VAULT_ADDR=$ADDR ROLE_ID=$ROLE_ID SECRET_ID=$SECRET_ID PG=127.0.0.1:$PG_PORT"

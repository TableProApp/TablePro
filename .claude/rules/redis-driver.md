---
paths:
  - "Plugins/RedisDriverPlugin/**/*"
---

# Redis driver

- **Cluster routing follows the server's `COMMAND` reply, merged over the curated table** in `RedisCommandRouting`, keyed `container|sub`. Redis 6 reports no routing tips, so the curated table is what makes `DBSIZE`, `KEYS` and `FLUSHDB` fan out.
- **An unknown command routes as keyless**, never by hashing its first argument.
- **After editing the curated table, run `scripts/probes/check-redis-command-routing.sh`** against Redis 7+.

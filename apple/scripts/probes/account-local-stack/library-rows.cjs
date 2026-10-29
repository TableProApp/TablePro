// Usage: node library-rows.cjs <team uuid>
// Prints the team's library rows, tombstones included, as one JSON array: kind, client_id, version, updated_via,
// deleted and name. Reads only. DATABASE_URL names the local stack's database.
const { Client } = require('pg');

const [team] = process.argv.slice(2);

(async () => {
  const client = new Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  try {
    const rows = await client.query(
      `select 'connection' as kind, client_id, version, updated_via, deleted_at is not null as deleted, payload->>'name' as name
         from library_connections where team_id = $1
       union all
       select 'folder', client_id, version, updated_via, deleted_at is not null, name from library_folders where team_id = $1
       union all
       select 'query', client_id, version, updated_via, deleted_at is not null, name from library_queries where team_id = $1
       order by kind, client_id`,
      [team],
    );
    console.log(JSON.stringify(rows.rows));
  } finally {
    await client.end();
  }
})().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});

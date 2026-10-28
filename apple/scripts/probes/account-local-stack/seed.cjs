// Usage: node seed.cjs <config.json to write> <email domain>
// Inserts, never deletes: a fresh account with a lifetime Starter license and a legacy key, a second one whose
// license already has 3 licensed devices, and a random key no license has. Rows are the ones the server's own
// import writes (license_keys holds the key's SHA-256). DATABASE_URL names the local stack's database.
const crypto = require('node:crypto');
const fs = require('node:fs');
const { Client } = require('pg');

const [configPath, domain] = process.argv.slice(2);
const suffix = crypto.randomBytes(4).toString('hex');
const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const newKey = () => Array.from({ length: 5 }, () =>
  Array.from({ length: 5 }, () => alphabet[crypto.randomInt(alphabet.length)]).join('')).join('-');

async function seedAccount(client, email, key, source, licensedDevices) {
  const product = await client.query("select id from products where plan = 'starter' and not archived order by cycle = 'lifetime' desc, polar_created_at desc limit 1");
  if (product.rows.length === 0) throw new Error('No Starter product is mirrored from the fake Polar yet');
  const account = await client.query('insert into accounts (email, email_verified_at) values ($1, now()) returning id', [email]);
  const license = await client.query(
    "insert into licenses (account_id, product_id, source, starts_at, note) values ($1, $2, $3, now(), 'account probe') returning id",
    [account.rows[0].id, product.rows[0].id, source],
  );
  const hash = crypto.createHash('sha256').update(key).digest();
  await client.query('insert into license_keys (license_id, key_hash, key_hint) values ($1, $2, $3)', [license.rows[0].id, hash, key.slice(-5)]);
  for (let i = 1; i <= licensedDevices; i++) {
    await client.query(
      "insert into devices (account_id, machine_id, platform, name, app_version, os_version, licensed_at) values ($1, $2, 'linux', $3, '2.0.0', 'Fedora 43', now() - interval '1 day')",
      [account.rows[0].id, crypto.randomBytes(32).toString('hex'), `Seeded ${i}`],
    );
  }
}

(async () => {
  const config = {
    signInEmail: `probe-signin-${suffix}@${domain}`,
    legacyEmail: `probe-legacy-${suffix}@${domain}`,
    legacyKey: newKey(),
    limitKey: newKey(),
    rejectedKey: newKey(),
  };
  const client = new Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  try {
    await client.query('begin');
    await seedAccount(client, config.legacyEmail, config.legacyKey, 'legacy', 0);
    await seedAccount(client, `probe-limit-${suffix}@${domain}`, config.limitKey, 'manual', 3);
    await client.query('commit');
  } catch (error) {
    await client.query('rollback');
    throw error;
  } finally {
    await client.end();
  }
  fs.writeFileSync(configPath, JSON.stringify(config), { mode: 0o600 });
  console.log(`seeded ${config.legacyEmail} and probe-limit-${suffix}@${domain}; signs in as ${config.signInEmail}`);
})().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});

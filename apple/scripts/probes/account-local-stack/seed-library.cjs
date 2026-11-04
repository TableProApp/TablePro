// Usage: node seed-library.cjs <config.json to write> <email domain>
// Inserts, never deletes: a team on a lifetime Team license with an owner, an admin and a member, each seated. The
// team license's own key signs the owner in, as an old build kept it; the admin and the member get seat keys. Only the
// owner has a name, so the library names the admin by address to owners and admins and not at all to members. The
// rows are the ones seed.ts and the server's import write. DATABASE_URL names the local stack's database.
const crypto = require('node:crypto');
const fs = require('node:fs');
const { Client } = require('pg');

const [configPath, domain] = process.argv.slice(2);
const suffix = crypto.randomBytes(4).toString('hex');
const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const newKey = () => Array.from({ length: 5 }, () =>
  Array.from({ length: 5 }, () => alphabet[crypto.randomInt(alphabet.length)]).join('')).join('-');

async function insertKey(client, licenseID, memberID, key) {
  const hash = crypto.createHash('sha256').update(key).digest();
  await client.query(
    'insert into license_keys (license_id, team_member_id, key_hash, key_hint) values ($1, $2, $3, $4)',
    [licenseID, memberID, hash, key.slice(-5)],
  );
}

(async () => {
  const config = {
    teamName: `Probe Library ${suffix}`,
    ownerName: `Probe Owner ${suffix}`,
    ownerEmail: `probe-lib-owner-${suffix}@${domain}`,
    adminEmail: `probe-lib-admin-${suffix}@${domain}`,
    memberEmail: `probe-lib-member-${suffix}@${domain}`,
    teamKey: newKey(),
    adminKey: newKey(),
    memberKey: newKey(),
  };
  const client = new Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  try {
    const product = await client.query("select id from products where plan = 'team' and not archived order by cycle = 'lifetime' desc, polar_created_at desc limit 1");
    if (product.rows.length === 0) throw new Error('No Team product is mirrored from the fake Polar yet');
    await client.query('begin');
    const team = await client.query('insert into teams (name) values ($1) returning id', [config.teamName]);
    config.teamUUID = team.rows[0].id;
    const license = await client.query(
      "insert into licenses (team_id, product_id, source, seats, starts_at, note) values ($1, $2, 'manual', 5, now(), 'library probe') returning id",
      [config.teamUUID, product.rows[0].id],
    );
    const licenseID = license.rows[0].id;
    for (const [email, name, role, key] of [
      [config.ownerEmail, config.ownerName, 'owner', null],
      [config.adminEmail, null, 'admin', config.adminKey],
      [config.memberEmail, null, 'member', config.memberKey],
    ]) {
      const account = await client.query(
        'insert into accounts (email, name, email_verified_at) values ($1, $2, now()) returning id',
        [email, name],
      );
      const member = await client.query(
        'insert into team_members (team_id, account_id, role, has_seat) values ($1, $2, $3, true) returning id',
        [config.teamUUID, account.rows[0].id, role],
      );
      if (key) await insertKey(client, licenseID, member.rows[0].id, key);
    }
    await insertKey(client, licenseID, null, config.teamKey);
    await client.query('commit');
  } catch (error) {
    await client.query('rollback');
    throw error;
  } finally {
    await client.end();
  }
  fs.writeFileSync(configPath, JSON.stringify(config), { mode: 0o600 });
  console.log(`seeded team "${config.teamName}" with ${config.ownerEmail}, ${config.adminEmail} and ${config.memberEmail}`);
})().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});

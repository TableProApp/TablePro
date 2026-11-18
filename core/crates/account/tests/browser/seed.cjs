'use strict';

// The database steps of tests/cloud_stack.rs that need no browser, written as tablepro-cloud's web/e2e/src/seed.ts
// writes them. Same NODE_PATH as portal.cjs.

const { Client } = require('pg');

function env(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is not set`);
  }
  return value;
}

const databaseURL = env('TABLEPRO_CLOUD_DATABASE_URL');
const email = env('TABLEPRO_CLOUD_EMAIL');
const [step] = process.argv.slice(2);

async function accountID(client, address) {
  const { rows } = await client.query('select id from accounts where email = $1', [address]);
  if (rows.length === 0) {
    throw new Error(`no account for ${address}`);
  }
  return rows[0].id;
}

async function unverify(client) {
  await client.query('update accounts set email_verified_at = null where id = $1', [await accountID(client, email)]);
}

// The account owns the team and TABLEPRO_CLOUD_MEMBER_EMAIL holds a seat, on a Team license of 5 seats.
async function team(client) {
  const owner = await accountID(client, email);
  const member = await accountID(client, env('TABLEPRO_CLOUD_MEMBER_EMAIL'));
  const product = await client.query(
    "select id from products where plan = 'team' and not archived order by cycle = 'lifetime' desc, polar_created_at desc limit 1",
  );
  if (product.rows.length === 0) {
    throw new Error('no Team product');
  }
  await client.query('begin');
  try {
    const { rows } = await client.query('insert into teams (name) values ($1) returning id', [`Stack ${email}`]);
    const teamID = rows[0].id;
    await client.query("insert into team_members (team_id, account_id, role, has_seat) values ($1, $2, 'owner', true)", [teamID, owner]);
    await client.query("insert into team_members (team_id, account_id, role, has_seat) values ($1, $2, 'member', true)", [teamID, member]);
    await client.query(
      "insert into licenses (team_id, product_id, source, seats, starts_at, note) values ($1, $2, 'manual', 5, now(), 'tablepro-account stack test')",
      [teamID, product.rows[0].id],
    );
    await client.query('commit');
  } catch (error) {
    await client.query('rollback');
    throw error;
  }
}

// What PUT /api/teams/{team_id}/sharing writes, for the team the account owns.
async function teamLinksOff(client) {
  await client.query(
    "update teams set public_links_disabled = true where id in (select team_id from team_members where account_id = $1 and role = 'owner')",
    [await accountID(client, email)],
  );
}

async function main() {
  const steps = { unverify, team, 'team-links-off': teamLinksOff };
  const run = steps[step];
  if (run === undefined) {
    throw new Error(`no step ${step}: ${Object.keys(steps).join(', ')}`);
  }
  const client = new Client({ connectionString: databaseURL });
  await client.connect();
  try {
    await run(client);
  } finally {
    await client.end();
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});

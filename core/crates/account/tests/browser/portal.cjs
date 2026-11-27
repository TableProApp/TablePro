'use strict';

// The browser steps of tests/cloud_stack.rs. CommonJS: NODE_PATH reaches require() only.

const fs = require('node:fs');
const puppeteer = require('puppeteer');
const { Client } = require('pg');

function env(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is not set`);
  }
  return value;
}

const accountURL = env('TABLEPRO_CLOUD_ACCOUNT_URL');
const mailURL = env('TABLEPRO_CLOUD_MAIL_URL');
const databaseURL = env('TABLEPRO_CLOUD_DATABASE_URL');
const chrome = env('TABLEPRO_CLOUD_CHROME');
const email = env('TABLEPRO_CLOUD_EMAIL');
const machineName = env('TABLEPRO_CLOUD_MACHINE_NAME');
const profile = env('TABLEPRO_CLOUD_PROFILE');
const grant = process.env.TABLEPRO_CLOUD_GRANT ?? '';
// Licensed devices to give the account before the app asks, the first with an offline file.
const seedDevices = Number(process.env.TABLEPRO_CLOUD_SEED_DEVICES ?? '0');
// Where the redirect to the app goes instead of to the app, for an app the browser cannot reach.
const callbackFile = process.env.TABLEPRO_CLOUD_CALLBACK_FILE ?? '';
const [step, authorizeURL] = process.argv.slice(2);
const signInSubject = /^Your TablePro sign-in code$/;

async function signInEmails() {
  const response = await fetch(`${mailURL}/_e2e/emails?to=${encodeURIComponent(email)}`);
  if (!response.ok) {
    throw new Error(`the fake SES answered ${response.status}`);
  }
  return (await response.json()).filter((sent) => signInSubject.test(sent.subject));
}

async function codeAfter(seen) {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    const sent = (await signInEmails())[seen];
    const code = sent && /^\s*(\d{6})\s*$/m.exec(sent.text)?.[1];
    if (code) {
      return code;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`no sign-in code reached ${email}`);
}

// The stack sends 5 sign-in emails an hour per address and 20 per client IP.
async function hasSession(page) {
  await page.goto(`${accountURL}/`);
  await page.waitForFunction(
    () =>
      location.pathname.startsWith('/sign-in') ||
      [...document.querySelectorAll('button')].some(
        (button) => (button.getAttribute('aria-label') ?? button.textContent).trim() === 'Sign out',
      ),
  );
  return !new URL(page.url()).pathname.startsWith('/sign-in');
}

async function signInToPortal(page) {
  if (await hasSession(page)) {
    return;
  }
  const seen = (await signInEmails()).length;
  await page.goto(`${accountURL}/sign-in`);
  await page.locator('::-p-aria(Email)').fill(email);
  await page.locator('::-p-aria([name="Continue with email"][role="button"])').click();
  await page.locator('::-p-aria([name="Check your email"][role="heading"])').wait();
  await page.locator('::-p-aria(6-digit code)').fill(await codeAfter(seen));
  await page.locator('::-p-aria([name="Sign in"][role="button"])').click();
  await page.waitForFunction(() => location.pathname === '/sign-in/passkey' || !location.pathname.startsWith('/sign-in'));
  if (new URL(page.url()).pathname === '/sign-in/passkey') {
    await page.locator('::-p-aria([name="Skip"][role="button"])').click();
  }
  await page.locator('::-p-aria([name="Sign out"][role="button"])').wait();
}

// The rows an admin grant writes, as tablepro-cloud's web/e2e/src/seed.ts does.
async function grantStarter() {
  const client = new Client({ connectionString: databaseURL });
  await client.connect();
  try {
    const product = await client.query(
      "select id from products where plan = 'starter' and not archived order by cycle = 'lifetime' desc, polar_created_at desc limit 1",
    );
    const account = await client.query('select id from accounts where email = $1', [email]);
    if (product.rows.length === 0 || account.rows.length === 0) {
      throw new Error(`no Starter product or no account for ${email}`);
    }
    await client.query(
      "insert into licenses (account_id, product_id, source, starts_at, note) values ($1, $2, 'manual', now(), 'tablepro-account stack test')",
      [account.rows[0].id, product.rows[0].id],
    );
  } finally {
    await client.end();
  }
}

// Seeded as a machine on another account's license would be: the rows POST /v2/devices and an offline file write.
async function seedLicensedDevices() {
  const client = new Client({ connectionString: databaseURL });
  await client.connect();
  try {
    const account = await client.query('select id from accounts where email = $1', [email]);
    for (let index = 0; index < seedDevices; index += 1) {
      const machineID = [...crypto.getRandomValues(new Uint8Array(32))].map((byte) => byte.toString(16).padStart(2, '0')).join('');
      await client.query(
        `insert into devices (account_id, machine_id, platform, name, app_version, os_version, licensed_at, last_seen_at, offline_until)
         values ($1, $2, 'linux', $3, '0.1.0', 'Ubuntu 26.04', now() - interval '1 day', now() - interval '2 hours', $4)`,
        [account.rows[0].id, machineID, `Seeded ${index + 1}`, index === 0 ? new Date(Date.now() + 30 * 86_400_000) : null],
      );
    }
  } finally {
    await client.end();
  }
}

async function approve(page) {
  const callback = new URL('/oauth/callback', new URL(authorizeURL).searchParams.get('redirect_uri'));
  if (callbackFile !== '') {
    await page.setRequestInterception(true);
    page.on('request', (request) => {
      if (request.url().startsWith(callback.href)) {
        fs.writeFileSync(callbackFile, request.url());
        request.respond({ status: 200, contentType: 'text/plain', body: 'Back in the app' });
      } else {
        request.continue();
      }
    });
  }
  await page.goto(authorizeURL);
  const heading = await page.locator('h1').map((element) => element.textContent).wait();
  if (!heading.includes(machineName)) {
    throw new Error(`the confirmation screen does not name the machine: ${heading}`);
  }
  const landed = page.waitForNavigation({ waitUntil: 'load' });
  await page.locator('::-p-aria([name="Sign in to TablePro for Linux"][role="button"])').click();
  await landed;
  if (!page.url().startsWith(callback.origin)) {
    throw new Error(`the browser went to ${page.url()} instead of ${callback.origin}`);
  }
}

async function offlineFile(page) {
  const [status, body] = await page.evaluate(
    async (machineID, name) => {
      const response = await fetch('/api/offline-entitlements', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ machine_id: machineID, platform: 'linux', name }),
      });
      return [response.status, await response.text()];
    },
    env('TABLEPRO_CLOUD_MACHINE_ID'),
    machineName,
  );
  if (status !== 200) {
    throw new Error(`the portal answered ${status}: ${body}`);
  }
  fs.writeFileSync(env('TABLEPRO_CLOUD_OUTPUT'), body);
}

async function removeDevice(page) {
  await page.goto(`${accountURL}/devices`);
  await page.locator(`::-p-aria([name="More actions for ${machineName}"][role="button"])`).click();
  await page.locator('::-p-aria([name="Remove device…"][role="menuitem"])').click();
  await page.locator('::-p-aria([name="Remove device"][role="button"])').click();
  await page.waitForFunction((name) => document.body.innerText.includes(`Removed ${name}.`), {}, machineName);
}

async function main() {
  const browser = await puppeteer.launch({
    executablePath: chrome,
    headless: 'shell',
    defaultViewport: { width: 1280, height: 800 },
    userDataDir: profile,
  });
  try {
    const page = await browser.newPage();
    await signInToPortal(page);
    if (step === 'approve') {
      if (grant === 'starter') {
        await grantStarter();
      }
      if (seedDevices > 0) {
        await seedLicensedDevices();
      }
      await approve(page);
    } else if (step === 'remove-device') {
      await removeDevice(page);
    } else if (step === 'offline-file') {
      await offlineFile(page);
    } else {
      throw new Error(`no step ${step}: approve <authorize URL>, remove-device or offline-file`);
    }
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});

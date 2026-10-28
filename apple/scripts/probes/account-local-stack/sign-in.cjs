// Usage: node sign-in.cjs <authorize URL> <email>
// Signs a new account in at the account pages with the emailed 6-digit code, grants it a lifetime Starter license
// before the app exchanges the code, and prints the app.tablepro: redirect it caught (CALLBACK). It then opens the
// same authorize URL with the session and prints the confirmation screen's text (CONFIRM) without approving it.
// MAIL_URL is the fake Resend, DATABASE_URL the stack's database, PROBE_CHROME an optional Chrome to drive.
const puppeteer = require('puppeteer');
const { Client } = require('pg');

const [authorizeURL, email] = process.argv.slice(2);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function codes() {
  const response = await fetch(`${process.env.MAIL_URL}/_e2e/emails?to=${encodeURIComponent(email)}`);
  return (await response.json()).filter((sent) => sent.subject === 'Sign in to TablePro');
}

async function codeAfter(seen) {
  for (const deadline = Date.now() + 20000; Date.now() < deadline; await sleep(250)) {
    const sent = (await codes())[seen];
    const code = sent && /^\s*(\d{6})\s*$/m.exec(sent.text)?.[1];
    if (code) return code;
  }
  throw new Error(`No sign-in code for ${email}`);
}

async function grantStarter() {
  const client = new Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  try {
    const product = await client.query("select id from products where plan = 'starter' and not archived order by cycle = 'lifetime' desc, polar_created_at desc limit 1");
    const account = await client.query('select id from accounts where email = $1', [email]);
    await client.query("insert into licenses (account_id, product_id, source, starts_at, note) values ($1, $2, 'manual', now(), 'account probe')", [account.rows[0].id, product.rows[0].id]);
  } finally {
    await client.end();
  }
}

(async () => {
  const chrome = process.env.PROBE_CHROME;
  const browser = await puppeteer.launch(chrome ? { executablePath: chrome, headless: 'shell' } : { headless: true });
  let callback;
  try {
    const page = await browser.newPage();
    const caught = (url) => {
      if (!callback && url && url.startsWith('app.tablepro:')) callback = url;
    };
    page.on('response', (response) => caught(response.headers()['location']));
    page.on('request', (request) => caught(request.url()));
    page.on('requestfailed', (request) => caught(request.url()));

    const seen = (await codes()).length;
    await page.goto(authorizeURL, { waitUntil: 'networkidle0' }).catch(() => {});
    await page.locator('::-p-aria(Email)').fill(email);
    await page.locator('::-p-aria(Continue with email[role="button"])').click();
    await page.locator('::-p-aria(6-digit code)').fill(await codeAfter(seen));
    await page.locator('::-p-aria(Sign in[role="button"])').click();
    for (const deadline = Date.now() + 20000; !callback && Date.now() < deadline; await sleep(200)) {
      const skip = await page.$('::-p-aria(Skip[role="button"])');
      if (skip) await skip.click().catch(() => {});
    }
    if (!callback) throw new Error(`No app.tablepro: redirect; the page is at ${page.url()}`);
    await grantStarter();
    console.log(`CALLBACK ${callback}`);

    const second = await browser.newPage();
    await second.goto(authorizeURL, { waitUntil: 'networkidle0' }).catch(() => {});
    await sleep(1500);
    const text = (await second.evaluate(() => document.body.innerText)).replace(/\s+/g, ' ').trim();
    console.log(`CONFIRM ${text.slice(0, 400)}`);
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});

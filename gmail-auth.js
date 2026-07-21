/**
 * Run this ONCE per account to authorize Billington to access a Gmail inbox.
 *
 * Usage:
 *   node gmail-auth.js                          # authorise hargobind@raylo.com  (GMAIL_REFRESH_TOKEN)
 *   node gmail-auth.js billingoperations        # authorise billingoperations@raylo.com  (GMAIL_BILLING_OPS_REFRESH_TOKEN)
 *
 * Prerequisites:
 *   1. Gmail API enabled in GCP Console (raylo-production project)
 *   2. OAuth 2.0 client ID created (type: Desktop app)
 *   3. GMAIL_CLIENT_ID and GMAIL_CLIENT_SECRET added to .env
 */

require("dotenv").config({ path: require("path").join(__dirname, ".env"), override: true });

const { google } = require("googleapis");
const readline = require("readline");
const fs = require("fs");
const path = require("path");

const CLIENT_ID = process.env.GMAIL_CLIENT_ID;
const CLIENT_SECRET = process.env.GMAIL_CLIENT_SECRET;

if (!CLIENT_ID || !CLIENT_SECRET) {
  console.error("❌  GMAIL_CLIENT_ID and GMAIL_CLIENT_SECRET must be set in .env first.");
  process.exit(1);
}

const arg = process.argv[2] || "";
const isBillingOps = arg === "billingoperations" || arg === "billing";

const accountHint = isBillingOps ? "billingoperations@raylo.com" : "hargobind@raylo.com";
const envKey = isBillingOps ? "GMAIL_BILLING_OPS_REFRESH_TOKEN" : "GMAIL_REFRESH_TOKEN";

const SCOPES = [
  "https://www.googleapis.com/auth/gmail.readonly",
];

const auth = new google.auth.OAuth2(CLIENT_ID, CLIENT_SECRET, "urn:ietf:wg:oauth:2.0:oob");

const authUrl = auth.generateAuthUrl({
  access_type: "offline",
  scope: SCOPES,
  prompt: "consent",
  login_hint: accountHint,
});

console.log(`\n📧  Billington Gmail Authorization — ${accountHint}\n`);
console.log(`1. Open this URL in your browser (sign in as ${accountHint}):\n`);
console.log("   " + authUrl);
console.log("\n2. Authorize the app, then copy the code shown.\n");

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });

rl.question("Paste the code here: ", async (code) => {
  rl.close();
  try {
    const { tokens } = await auth.getToken(code.trim());

    if (!tokens.refresh_token) {
      console.error("\n❌  No refresh token received. Try revoking access at https://myaccount.google.com/permissions and run this script again.");
      process.exit(1);
    }

    // Write to .env
    const envPath = path.join(__dirname, ".env");
    const envContents = fs.readFileSync(envPath, "utf-8");
    const updated = envContents.includes(`${envKey}=`)
      ? envContents.replace(new RegExp(`${envKey}=.*`), `${envKey}=${tokens.refresh_token}`)
      : envContents + `\n${envKey}=${tokens.refresh_token}\n`;
    fs.writeFileSync(envPath, updated);

    console.log(`\n✅  Done! ${envKey} saved to .env.`);
    console.log("    Now add it to Railway env vars and redeploy:");
    console.log(`    ${envKey}=<the token above>`);
    console.log("\n    Or restart locally: npx pm2 restart bill-ling --update-env");
  } catch (err) {
    console.error("\n❌  Error exchanging code:", err.message);
    process.exit(1);
  }
});

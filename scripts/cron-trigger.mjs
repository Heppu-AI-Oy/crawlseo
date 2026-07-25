#!/usr/bin/env node
/**
 * Triggers a CrawlSEO cron job against the server running in this container.
 *
 * Usage: node scripts/cron-trigger.mjs <gsc-sync|crawl|vitals>
 *
 * Exists as a file rather than an inline `node -e` one-liner so the scheduler's
 * command field stays free of nested quotes, and so it does not depend on curl
 * or a particular wget variant being present in the runtime image.
 *
 * Exits non-zero when the job fails, so the scheduler reports a failure instead
 * of a silent success.
 */

const JOBS = ["gsc-sync", "crawl", "vitals"];

const job = process.argv[2];
if (!JOBS.includes(job)) {
  console.error(`usage: cron-trigger.mjs <${JOBS.join("|")}>`);
  process.exit(2);
}

const secret = process.env.CRON_SECRET;
if (!secret) {
  console.error("CRON_SECRET is not set — refusing to call the cron endpoint");
  process.exit(2);
}

const port = process.env.PORT || "3000";
const url = `http://127.0.0.1:${port}/api/cron/${job}`;

try {
  const res = await fetch(url, {
    method: "POST",
    headers: { Authorization: `Bearer ${secret}` },
  });
  const body = await res.text();
  console.log(`${job}: HTTP ${res.status}`);
  console.log(body.slice(0, 4000));
  process.exit(res.ok ? 0 : 1);
} catch (error) {
  console.error(`${job}: request failed — ${error?.message ?? error}`);
  process.exit(1);
}

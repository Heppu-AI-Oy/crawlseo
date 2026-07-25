import { timingSafeEqual } from "node:crypto";
import { db } from "@/lib/db";
import { syncGSCDataForSite } from "@/lib/workers/gsc-sync";
import { syncVitalsForSite } from "@/lib/workers/vitals-sync";
import { runSiteCrawl } from "@/lib/crawler/engine";

// Jobs mutate the database and read env at request time — never prerender.
export const dynamic = "force-dynamic";
export const maxDuration = 300;

const JOBS = ["gsc-sync", "crawl", "vitals"] as const;
type Job = (typeof JOBS)[number];

function isJob(value: string): value is Job {
  return (JOBS as readonly string[]).includes(value);
}

/**
 * Constant-time bearer check against CRON_SECRET.
 *
 * Unlike the dashboard routes there is no session here: the scheduler is a
 * machine. Each job resolves the owning user from the Site row instead, since
 * `userId` is what locates the stored Google OAuth refresh token.
 */
function isAuthorized(req: Request, secret: string): boolean {
  const header = req.headers.get("authorization") ?? "";
  const presented = header.startsWith("Bearer ") ? header.slice(7) : "";

  const a = Buffer.from(presented);
  const b = Buffer.from(secret);
  // timingSafeEqual throws on length mismatch; length is not the secret.
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

interface SiteOutcome {
  siteId: string;
  domain: string;
  ok: boolean;
  detail: unknown;
}

async function runGscSync(): Promise<SiteOutcome[]> {
  const sites = await db.site.findMany({
    where: { gscProperty: { not: null } },
    select: { id: true, domain: true, userId: true },
  });

  const outcomes: SiteOutcome[] = [];
  for (const site of sites) {
    const result = await syncGSCDataForSite(site.userId, site.id);
    outcomes.push({
      siteId: site.id,
      domain: site.domain,
      ok: result.success,
      detail: result,
    });
  }
  return outcomes;
}

async function runVitals(): Promise<SiteOutcome[]> {
  const sites = await db.site.findMany({
    select: { id: true, domain: true, userId: true },
  });

  const outcomes: SiteOutcome[] = [];
  for (const site of sites) {
    try {
      const result = await syncVitalsForSite(site.userId, site.id, 5);
      outcomes.push({ siteId: site.id, domain: site.domain, ok: true, detail: result });
    } catch (error) {
      outcomes.push({
        siteId: site.id,
        domain: site.domain,
        ok: false,
        detail: error instanceof Error ? error.message : "Unknown error",
      });
    }
  }
  return outcomes;
}

async function runCrawl(): Promise<SiteOutcome[]> {
  const maxPages = Number(process.env.CRON_CRAWL_MAX_PAGES) || 200;
  const sites = await db.site.findMany({
    select: { id: true, domain: true },
  });

  const outcomes: SiteOutcome[] = [];
  for (const site of sites) {
    // Mirrors the 409 guard in the dashboard route: never stack crawls.
    const running = await db.crawl.findFirst({
      where: { siteId: site.id, status: "RUNNING" },
      select: { id: true },
    });
    if (running) {
      outcomes.push({
        siteId: site.id,
        domain: site.domain,
        ok: true,
        detail: { skipped: "crawl already running", crawlId: running.id },
      });
      continue;
    }

    try {
      // Awaited, not fire-and-forget: the scheduler has no request deadline,
      // and a detached promise would be killed by container shutdown.
      const result = await runSiteCrawl(site.id, site.domain, maxPages);
      outcomes.push({ siteId: site.id, domain: site.domain, ok: true, detail: result });
    } catch (error) {
      outcomes.push({
        siteId: site.id,
        domain: site.domain,
        ok: false,
        detail: error instanceof Error ? error.message : "Unknown error",
      });
    }
  }
  return outcomes;
}

export async function POST(
  req: Request,
  { params }: { params: Promise<{ job: string }> }
) {
  const secret = process.env.CRON_SECRET;
  if (!secret) {
    // Refuse rather than run unauthenticated — an open trigger would let
    // anyone burn the site's PageSpeed quota and hammer the crawl target.
    console.error("[cron] CRON_SECRET is not set — refusing to run jobs");
    return Response.json({ error: "CRON_SECRET not configured" }, { status: 503 });
  }

  if (!isAuthorized(req, secret)) {
    return Response.json({ error: "Unauthorized" }, { status: 401 });
  }

  const { job } = await params;
  if (!isJob(job)) {
    return Response.json({ error: `Unknown job "${job}"`, known: JOBS }, { status: 404 });
  }

  const startedAt = Date.now();
  console.log(`[cron] ${job}: starting`);

  try {
    const outcomes =
      job === "gsc-sync"
        ? await runGscSync()
        : job === "vitals"
          ? await runVitals()
          : await runCrawl();

    const failed = outcomes.filter((o) => !o.ok);
    const durationMs = Date.now() - startedAt;
    console.log(
      `[cron] ${job}: ${outcomes.length - failed.length}/${outcomes.length} ok in ${durationMs}ms`
    );

    // Non-2xx on partial failure so the scheduled task shows red in Coolify
    // instead of silently reporting success.
    return Response.json(
      { job, durationMs, total: outcomes.length, failed: failed.length, outcomes },
      { status: failed.length > 0 ? 500 : 200 }
    );
  } catch (error) {
    console.error(`[cron] ${job}: fatal`, error);
    return Response.json(
      { job, error: error instanceof Error ? error.message : "Unknown error" },
      { status: 500 }
    );
  }
}

FROM node:20-alpine AS base

FROM base AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

# The Prisma CLI is needed at container start to apply migrations, but it is not
# traced into .next/standalone (the app only imports @prisma/client). Copying
# node_modules/prisma + node_modules/@prisma out of the build is not enough
# either: @prisma/config requires `effect`, which npm hoists to the top level of
# node_modules, so the CLI dies with MODULE_NOT_FOUND.
#
# Install the CLI into its own self-contained tree instead. It lands at
# /app/migrator/node_modules in the runner so Node's upward resolution from
# .../node_modules/prisma/build/index.js finds every transitive dependency.
FROM base AS migrator
WORKDIR /lock
COPY package-lock.json ./
RUN PRISMA_VERSION="$(node -p "require('/lock/package-lock.json').packages['node_modules/prisma'].version")" \
 && mkdir -p /migrator && cd /migrator \
 && npm install --no-save --no-audit --no-fund "prisma@${PRISMA_VERSION}"

FROM base AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# `next build` collects page data, which evaluates lib/auth.ts at module scope,
# and that asserts the Google OAuth credentials exist. The values are never
# *used* during the build (they are read again at request time in the Node
# runtime, and are not NEXT_PUBLIC_ so nothing is inlined into client bundles),
# so placeholders satisfy the assertion without baking secrets into the image.
# Real credentials come from the runtime environment.
ARG GOOGLE_CLIENT_ID=build-time-placeholder
ARG GOOGLE_CLIENT_SECRET=build-time-placeholder
RUN npx prisma generate
RUN npm run build

FROM base AS runner
WORKDIR /app
ENV NODE_ENV=production
# curl is not in node:*-alpine, but orchestrators (Coolify, and the healthcheck
# in docker-compose.yml) reach for it to probe /api/health. Without it the
# container is reported unhealthy despite serving correctly.
RUN apk add --no-cache curl
RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs
COPY --from=builder /app/public ./public
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/prisma ./prisma
COPY --from=builder /app/node_modules/.prisma ./node_modules/.prisma
# Prisma CLI, self-contained (see the migrator stage). Ships in the image so
# migrations run offline instead of `npx` fetching the CLI from the registry on
# every boot as a non-root user with no writable cache.
# (prisma.config.ts is deliberately not copied — it needs dotenv + a TS loader;
# without it the CLI falls back to prisma/schema.prisma, which is copied above.)
COPY --from=migrator /migrator/node_modules ./migrator/node_modules
# Entry point for external schedulers (Coolify Scheduled Tasks etc.).
COPY --from=builder /app/scripts/cron-trigger.mjs ./scripts/cron-trigger.mjs
COPY --from=builder /app/docker-entrypoint.sh ./docker-entrypoint.sh
RUN chmod +x ./docker-entrypoint.sh
USER nextjs
EXPOSE 3000
ENV PORT=3000
# Docker sets HOSTNAME to the container id, and the Next.js standalone server
# binds to `process.env.HOSTNAME || '0.0.0.0'` — so without this it binds to the
# container id instead of all interfaces and the reverse proxy gets no backend.
ENV HOSTNAME=0.0.0.0
CMD ["./docker-entrypoint.sh"]

FROM node:20-alpine AS base

FROM base AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

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
RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs
COPY --from=builder /app/public ./public
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/prisma ./prisma
COPY --from=builder /app/node_modules/.prisma ./node_modules/.prisma
# The standalone bundle only traces what the app imports, so the Prisma CLI is
# absent from it. Ship the CLI and its engines explicitly: otherwise `npx prisma`
# tries to fetch the package from the npm registry on every boot, as a non-root
# user with no writable cache, and the container fails before it ever serves.
# (prisma.config.ts is deliberately not copied — it needs dotenv + a TS loader;
# without it the CLI falls back to prisma/schema.prisma, which is copied above.)
COPY --from=builder /app/node_modules/prisma ./node_modules/prisma
COPY --from=builder /app/node_modules/@prisma ./node_modules/@prisma
USER nextjs
EXPOSE 3000
ENV PORT=3000
CMD ["sh", "-c", "node ./node_modules/prisma/build/index.js migrate deploy && node server.js"]

#!/bin/sh
# Container entrypoint: apply migrations, then start the Next.js standalone server.
#
# Kept as a script rather than an inline `sh -c "a && b"` CMD so that a failure
# in either step names itself in the logs. A chained CMD exits with a bare
# non-zero code, and an exited container's logs are not retrievable through the
# Coolify API — leaving nothing to debug from.

set -u

echo "[entrypoint] starting; NODE_ENV=${NODE_ENV:-unset} PORT=${PORT:-unset} HOSTNAME=${HOSTNAME:-unset}"

if [ -z "${DATABASE_URL:-}" ]; then
  echo "[entrypoint] FATAL: DATABASE_URL is not set"
  exit 1
fi

# Print the target without leaking the password.
echo "[entrypoint] database host: $(echo "$DATABASE_URL" | sed -e 's#.*@##' -e 's#?.*##')"

echo "[entrypoint] running: prisma migrate deploy"
node ./migrator/node_modules/prisma/build/index.js migrate deploy
migrate_status=$?
echo "[entrypoint] prisma migrate deploy exited ${migrate_status}"

if [ "$migrate_status" -ne 0 ]; then
  if [ "${ALLOW_START_WITHOUT_MIGRATIONS:-0}" = "1" ]; then
    # Explicit, opt-in escape hatch for diagnosing a boot failure: the server
    # comes up against an unmigrated schema so its logs can be read at all.
    # Never leave this set in normal operation.
    echo "[entrypoint] WARNING: migrations failed but ALLOW_START_WITHOUT_MIGRATIONS=1 — starting anyway"
  else
    echo "[entrypoint] FATAL: refusing to start with unapplied migrations"
    exit "$migrate_status"
  fi
fi

echo "[entrypoint] starting server on ${HOSTNAME:-0.0.0.0}:${PORT:-3000}"
exec node server.js

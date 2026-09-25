#!/bin/bash
# Installs or upgrades Lago on every `docker compose up`; safe to repeat.
# Runs as root (volumes' owners); Lago's commands run as LAGO_UID:
# - RSA key in the `keys` volume (config/keys/private.pem), generated once: it
#   signs webhooks and login tokens. Back it up (see backup.sh).
# - `rails db:migrate` + Lago's predefined roles (what Lago's migrate.sh does).
# - scripts/configure.rb: organization, admin user and initial settings.
set -euo pipefail
cd /app

lago() { HOME=/tmp setpriv --reuid="${LAGO_UID}" --regid="${LAGO_UID}" --clear-groups -- "$@"; }

echo "==> RSA key"
key=config/keys/private.pem
if [ ! -s "${key}" ]; then
    (umask 077 && openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${key}.tmp" 2>/dev/null)
    mv "${key}.tmp" "${key}"
    echo "Generated ${key}"
fi
chown -R "${LAGO_UID}:${LAGO_UID}" config/keys
chmod 700 config/keys
chmod 600 "${key}"

# Uploads and PDFs written by the API and the worker.
find storage ! -user "${LAGO_UID}" -exec chown "${LAGO_UID}:${LAGO_UID}" {} +

echo "==> Migrations"
lago bundle exec rails db:migrate roles:seed_predefined

echo "==> Organization and settings"
lago bundle exec rails runner /usr/local/share/stack/scripts/configure.rb

echo "==> Done: Lago ${LAGO_VERSION:-}"
echo "    App: ${LAGO_URL} (${LAGO_ADMIN_EMAIL})"
echo "    API: ${LAGO_URL}/api/v1 (API key: Developers > API keys)"

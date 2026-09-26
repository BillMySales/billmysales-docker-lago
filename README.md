Lago Docker stack
=================

Docker Compose stack for [Lago](https://www.getlago.com) (open source
usage-based and subscription billing: plans, subscriptions, usage events,
invoices, webhooks), usable for local development and for simple production
deployments (a single server). Maintained by
[BillMySales](https://www.billmysales.com).

| Component   | Image                                         | Default version |
|-------------|-----------------------------------------------|-----------------|
| Web server  | `caddy:<ver>-alpine`                          | 2.11            |
| Lago API, worker, clock | `getlago/api`                     | v1.53.0         |
| Lago front  | `getlago/front`                               | v1.53.0         |
| PDFs        | `getlago/lago-gotenberg`                      | 8.15            |
| Database    | own image (`image/postgres`): `postgres:<ver>-alpine` + pg_partman | 15 (pg_partman 5.4.3) |
| Queue/cache | `redis:<ver>-alpine`                          | 7.4             |
| Mailpit     | `axllent/mailpit` (optional, dev)             | v1.31           |

Lago's official images (amd64 and arm64; tested on arm64) run the API (Rails:
Puma, Sidekiq, Clockwork) and the front (a static app on nginx). Gotenberg
8.15 is the one in Lago's production compose (the 7.8.2 of its main compose
is amd64-only). Lago uses pg_partman to partition its enriched events: Lago's
database image (`getlago/postgres-partman`) is stuck on PostgreSQL 15.0 and an
end-of-life Alpine, so `image/postgres` builds the same recipe on the current
`postgres:15-alpine` (15 is what Lago runs; ~35 s build). Lago's own
all-in-one image (`getlago/lago`) and its compose files (published database
ports, placeholder secrets) don't fit.

Requirements
------------

- Docker Engine 24+ with the Compose v2 plugin (`docker compose`, 2.24+).
- About 3 GB of disk for the images (Gotenberg alone 1.8 GB); 1.5 GB of RAM
  for the stack.
- Development: ports 8114, 8414 and 8025 free on the host.
- Production: a server with ports 80 and 443 reachable, and a DNS record for
  the site's domain pointing to it.

Quick start (development)
-------------------------

```shell
cp .env.dev.example .env
docker compose up -d           # builds the database image the first time
docker compose logs -f setup   # wait for "==> Done"
```

- App: http://localhost:8114 (user `admin@example.com`, password
  `admin12345`).
- REST API: http://localhost:8114/api/v1 (header
  `Authorization: Bearer dev-api-key` in development).
- Mailpit (every email Lago sends): http://localhost:8025

Production
----------

```shell
cp .env.prod.example .env
# Required: LAGO_URL, SITE_ADDRESS, SECRET_KEY_BASE, the three
# LAGO_ENCRYPTION_* keys, DB_PASSWORD, LAGO_ADMIN_EMAIL, LAGO_ADMIN_PASSWORD.
# Recommended: the SMTP_* values (without SMTP_HOST no emails are sent).
docker compose up -d
```

- Keep the secrets outside the server too: without the `LAGO_ENCRYPTION_*`
  values, a restored database's encrypted fields can't be read.
- With `SITE_ADDRESS` set to the domain, Caddy gets a Let's Encrypt certificate
  and renews it automatically (certificates live in the `caddy_data` volume).
- Behind another TLS-terminating proxy, use `SITE_ADDRESS=:80`.
- Compose refuses to start while a required value is missing.
- The `backup` profile is enabled by default in the production template.
- Behind an existing Traefik (no host ports), use `overrides/traefik.yaml`
  (see [Overrides](#overrides)).

Services
--------

| Service   | Profile   | Role                                                           |
|-----------|-----------|----------------------------------------------------------------|
| `db`      |           | PostgreSQL + pg_partman (with its background worker).          |
| `redis`   |           | Sidekiq queues, cache, Action Cable.                           |
| `setup`   |           | One-shot job (`scripts/setup.sh`), runs on every `up`.         |
| `api`     |           | REST API, GraphQL (front), payment providers' webhooks (Puma). |
| `worker`  |           | Sidekiq: billing, invoices, PDFs, webhooks, emails, events.    |
| `clock`   |           | Clockwork: schedules the periodic jobs (billing runs...).      |
| `front`   |           | The app (static files on the image's nginx).                   |
| `pdf`     |           | Gotenberg (Chromium): invoices and credit notes to PDF.        |
| `caddy`   |           | TLS and routing; the only published ports.                     |
| `console` | `tools`   | Rails console and commands.                                    |
| `backup`  | `backup`  | Database dump + storage + RSA key on a schedule.               |
| `mailpit` | `mailpit` | Development SMTP server that catches all mail.                 |

One site, like Lago's production setup: the REST API under `/api/v1`, other
API routes under `/api` (prefix stripped: file downloads, payment providers'
webhooks), `/graphql` and `/cable` (the front's API and live updates) and
`/rails/` (download redirects) to the API, everything else to the front.
Lago's Prometheus metrics (`/metrics`, no authentication) are not published.
The front gets the site's URL when it starts: changing `LAGO_URL` needs no
rebuild.

The Lago image has no user of its own and runs as root; the stack runs it as
`LAGO_UID` (1000), with `tmp/` in memory.

A single Sidekiq worker handles every queue (enough for one server); Lago's
production compose splits them into dedicated workers for high volumes.

### What `setup` does

- The RSA key (`keys` volume, `config/keys/private.pem`), generated once: it
  signs webhooks (JWT) and login tokens. Lago reads this file before its
  `LAGO_RSA_PRIVATE_KEY` variable (not set by the stack). **Back it up**:
  the `backup` service includes it.
- `rails db:migrate` and Lago's predefined roles (what Lago's `migrate.sh`
  does). On a new database Rails loads Lago's schema file instead of running
  the migrations, and that file doesn't configure pg_partman; `setup` then
  partitions the enriched events table as Lago's migration does (see
  [Notes](#configuration)).
- `scripts/configure.rb` (rails runner):
  - first run (no organization): the organization, its billing entity and the
    admin user (like Lago's `signup:seed_organization`), with the initial
    settings: Chile, CLP, documents in Spanish, and a tax (IVA 19%) applied
    by default. Later changes in the app are kept (Lago's own task finds the
    organization by name, so renaming it would create a second one; this
    script doesn't).
  - every run: the admin user (`LAGO_ADMIN_EMAIL`) exists with an admin
    membership (created if no user with that email exists: changing it
    later adds another one), and `LAGO_API_KEY`, if set, is one of the
    organization's API keys.

Common commands
---------------

```shell
docker compose ps                        # status: every service "healthy", setup "Exited (0)"
docker compose logs -f api worker        # logs
docker compose exec db psql -U lago lago # SQL shell
docker compose run --rm console          # Rails console (profile "tools")
docker compose run --rm console bin/rails runner 'puts Organization.count'
docker compose down                      # stop, keep data
docker compose down -v                   # stop and DELETE all data
```

Billing settings and the free edition
-------------------------------------

- Amounts are in the currency's smallest unit: CLP has no decimals, so
  `amount_cents: 19990` is $19.990. Taxes are added on top of the plan price
  (a $3.998 fee + $760 IVA = $4.758).
- Invoices and credit notes are rendered in `LAGO_DOCUMENT_LOCALE` (Spanish);
  amounts in Spanish use Spanish separators (`$19.990`): Lago's own Spanish
  locale uses English ones, overridden by
  `config/lago/locales/zz_stack_es.yml`.
- Subscriptions are billed per calendar month by default, so the first
  invoice is prorated; plans or subscriptions can use anniversary billing.
- **Free edition limits** (premium, with a `LAGO_LICENSE`): the timezone is
  always UTC (a billing period ends at midnight UTC, 20:00/21:00 in Chile, and
  invoice dates follow UTC), and Lago doesn't email invoices, credit notes or
  receipts. Lago still sends account emails (password resets, invitations,
  in English).
- Payment providers (Stripe, Adyen, GoCardless...) are configured in the app
  (Integrations).

Integrations (API and webhooks)
-------------------------------

- REST API at `<url>/api/v1` with an organization API key
  (`Authorization: Bearer <key>`, in the app under Developers > API keys, or
  a fixed one with `LAGO_API_KEY`).
- Webhook endpoints (app or `POST /api/v1/webhook_endpoints`) get events such
  as `invoice.created`, `invoice.generated` (PDF ready),
  `invoice.payment_status_updated`, `credit_note.created`, `customer.created`,
  `subscription.started`, signed with a JWT (RS256, the RSA key; public key
  at `GET /api/v1/webhooks/public_key`) or HMAC. A BillMySales integration
  would be a webhook receiver.
- Lago calls webhook URLs on any address, including the host
  (`http://host.docker.internal:<port>` from the containers).

Emails
------

SMTP comes from `SMTP_*`: Lago uses STARTTLS when the server offers it
(port 587), authenticates with `LOGIN` and doesn't support SMTPS (465);
without `SMTP_HOST` no email is sent. `SMTP_FROM` is the sender of account
emails.

Backups
-------

With the `backup` profile, the `backup` service writes `<timestamp>-db.dump`
(`pg_dump` custom format, pg_partman's configuration included) and
`<timestamp>-files.tar.gz` (storage: PDFs and uploads; the RSA key) to the
`backups` volume (or `./data/backups` with `overrides/local-dirs.yaml`) at
start and then every `BACKUP_INTERVAL_HOURS`, and deletes files older than
`BACKUP_KEEP_DAYS`. Files are readable by their owner only. The
`LAGO_ENCRYPTION_*` keys are in `.env`, not in the backups: keep them.

```shell
docker compose run --rm --no-deps backup now                  # back up now
docker compose run --rm --no-deps backup list                 # list timestamps
docker compose stop api worker clock                          # stop the app first
docker compose run --rm --no-deps backup restore <timestamp>  # database, storage, key
docker compose exec redis redis-cli FLUSHALL                  # queues and cache of the old data
docker compose up -d
```

`--no-deps` keeps the commands from starting `setup` first (with damaged
data `setup` fails and the restore would never run); the database must be
running (`docker compose up -d db` if the stack is down). A restore replaces
the database with a fresh copy, so nothing created after the backup remains.

Upgrades
--------

Back up first, then change `LAGO_VERSION` in `.env` and run
`docker compose up -d`: the new images are pulled and `setup` runs the
migrations before the API starts. Read Lago's release notes; Lago releases a
minor version every few weeks. The database image (the only one built
locally) is built by `up -d` whenever its tag changes (`POSTGRES_VERSION`,
`PARTMAN_VERSION`; set `PARTMAN_SHA256` for another pg_partman release); for
PostgreSQL patch releases rebuild it (`docker compose build --pull db`, then
`docker compose up -d`). A new PostgreSQL major version needs a dump and
restore.

Overrides
---------

Optional compose files in `overrides/`, enabled with `COMPOSE_FILE` in `.env`
(several are combined with `:`). Each file documents its variables.

```shell
COMPOSE_FILE=compose.yaml:overrides/traefik.yaml:overrides/local-dirs.yaml
```

| File                        | Purpose                                                            |
|-----------------------------|--------------------------------------------------------------------|
| `overrides/traefik.yaml`    | Publish through an existing Traefik on a shared external network:  |
|                             | no host ports, Traefik terminates TLS (`TRAEFIK_HOST`, ...).       |
| `overrides/local-dirs.yaml` | Database, Redis, storage, key, Caddy and backups in local          |
|                             | directories (`DATA_DIR`, default `./data`) instead of volumes.     |

A local `compose.override.yaml` (gitignored) is also loaded automatically by
Docker Compose, for changes specific to one machine.

Configuration
-------------

Every variable is documented in `.env.prod.example`. Main groups:

- **Site and network**: `LAGO_URL`, `SITE_ADDRESS`, `HTTP_BIND`, `HTTP_PORT`,
  `HTTPS_PORT`.
- **Credentials**: `SECRET_KEY_BASE`, `LAGO_ENCRYPTION_PRIMARY_KEY`,
  `LAGO_ENCRYPTION_DETERMINISTIC_KEY`, `LAGO_ENCRYPTION_KEY_DERIVATION_SALT`,
  `DB_PASSWORD`, `LAGO_ADMIN_EMAIL`, `LAGO_ADMIN_PASSWORD` (required),
  `LAGO_API_KEY`.
- **Organization** (first install only): `LAGO_ORG_NAME`, `LAGO_COUNTRY`,
  `LAGO_CURRENCY`, `LAGO_CITY`, `LAGO_DOCUMENT_LOCALE`, `LAGO_TAX_RATE`,
  `LAGO_TAX_NAME`.
- **Edition and telemetry**: `LAGO_LICENSE`, `LAGO_DISABLE_SEGMENT`,
  `LAGO_DISABLE_PDF_GENERATION`.
- **Versions**: `LAGO_VERSION`, `GOTENBERG_VERSION`, `POSTGRES_VERSION`,
  `PARTMAN_VERSION`, `PARTMAN_SHA256`, `REDIS_VERSION`, `CADDY_VERSION`,
  ...
- **Mail**: `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`,
  `SMTP_FROM`.
- **Processes, resources and logs**: `LAGO_UID`, `WEB_CONCURRENCY`,
  `RAILS_MAX_THREADS`, `SIDEKIQ_CONCURRENCY`, `*_MEMORY_LIMIT` per service,
  `UPLOAD_MAX_SIZE`, `LOG_MAX_SIZE`, `LOG_MAX_FILE`.

Notes:

- Production settings: signups disabled (the organization comes from
  `setup`), Sidekiq's web UI off, Segment telemetry off (Lago sends usage
  data by default).
- Lago assumes every request is HTTPS unless `LAGO_DISABLE_SSL` is set: the
  stack sets it and Rails takes the scheme from Caddy's `X-Forwarded-Proto`,
  so links follow `LAGO_URL` (`http://` in development, `https://` behind
  Caddy or Traefik).
- **Partitioned events**: on a new database Rails loads `db/structure.sql`,
  which has Lago's partitioned `enriched_events` table and its default
  partition but not pg_partman's configuration nor the monthly partitions,
  so pg_partman would never manage the table (also with Lago's own images).
  `setup` repeats Lago's partitioning migration while the default partition
  is empty. pg_partman is optional for Lago's migrations (skipped when the
  extension is missing) and Lago never runs pg_partman's maintenance: only
  pg_partman's background worker (enabled in `db`) creates the future
  partitions, hourly. An upgraded database ends up identical to a
  fresh one.
- From inside the containers, the host machine is reachable as
  `host.docker.internal`.

Security
--------

- No default secrets: compose fails if the required passwords and secrets are
  missing. The development template uses public values; never use it on a
  server.
- Lago runs as an unprivileged user; only Caddy (and Mailpit in development)
  publishes ports; the API, the front, Gotenberg (JavaScript disabled),
  PostgreSQL and Redis are internal. `HTTP_BIND` defaults to `127.0.0.1`.
- Lago's metrics endpoint is not published; its admin and data APIs refuse
  every request (no `ADMIN_API_KEY`/`LAGO_DATA_API_BEARER_TOKEN` set).
- The RSA key volume is private (mode 700).
- Lago logs request parameters (GraphQL included); emails, passwords and
  tokens are filtered from GraphQL variables (how the front sends them), not
  from values written inline in a query: API clients should pass secrets as
  variables.
- Not included: a web application firewall or off-site backup copies.

Validation
----------

What was checked for this stack (2026-09-24):

- Clean start (`down -v` + `up -d`, images pulled, database image built) in
  about 45 s after the first run; every service `healthy`, `setup`
  `Exited (0)`; a second run makes no changes; a renamed organization and
  changed settings are kept (no second organization).
- The app and its assets, login (GraphQL), live updates (`/cable`
  WebSocket), REST API with a fixed key; customer, plan in CLP, subscription;
  invoice ($3.998 prorated + $760 IVA = $4.758) and its PDF in Spanish with
  `$4.758` (downloaded through `/api/rails/...`).
- Webhooks to a receiver on the host (`customer.created`, `plan.created`,
  `subscription.started`, `invoice.created`, `invoice.generated`), signed
  with JWT RS256.
- Password reset email through SMTP to Mailpit, with the right link.
- pg_partman: monthly partitions created, maintenance runs.
- Backup and restore (a customer created after the backup is gone; storage,
  key and PDFs back).
- Upgrade v1.50.0 → v1.53.0 with data: migrations, invoices kept, billing
  afterwards; the upgraded schema (public and partman: columns, indexes,
  constraints) is identical to a fresh v1.53.0 install's.
- HTTPS with `SITE_ADDRESS=localhost` (front, PDF links and email links on
  `https://localhost:8414`); URL change and back; overrides: Traefik v3.6
  routing with no host ports (client IP kept), local directories (fresh
  install).
- Not tested: issuing a real Let's Encrypt certificate (needs a public
  domain), payment providers, the premium edition, a real SMTP provider.

Resource usage
--------------

Idle, after a few requests: API ~510 MiB, Clockwork ~355 MiB, Sidekiq ~345
MiB, PostgreSQL ~60 MiB, Gotenberg ~45 MiB, Caddy ~13 MiB, front ~9 MiB,
Redis ~5 MiB (about 1.35 GiB in total). Images: API 654 MB, Gotenberg
1.8 GB, database 294 MB.

License
-------

[MIT](LICENSE) (the stack; Lago itself is AGPL-3.0).

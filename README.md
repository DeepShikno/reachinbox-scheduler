# ReachInbox – Full-stack Email Job Scheduler

TypeScript • Express • BullMQ + Redis • MySQL • Elasticsearch • Ethereal SMTP • React + Tailwind (Vite)

```
backend/    Express API + BullMQ worker      frontend/   React dashboard
```

## 1. Run the backend
Needs MySQL, Redis and Elasticsearch (hosted or local). `docker compose up -d` starts all three locally if you prefer, but Docker is optional.
```bash
cd backend
cp .env.example .env        # fill in DB / Redis / ES / Google / Slack values
npm install
npm run migrate             # creates tables from sql/schema.sql (skips CREATE DATABASE/USE for hosted DBs)
npm run dev:api             # terminal 1 -> http://localhost:4000   (Bull Board: /admin/queues)
npm run dev:worker          # terminal 2
```
Production: `npm run build && npm run start:api` and `npm run start:worker`.

## 2. Run the frontend
```bash
cd frontend
npm install
npm run dev                 # http://localhost:5173  (Vite proxies /api and /auth to :4000)
```

## 3. Ethereal Email (fake SMTP) and senders
No manual setup: the first time a user schedules, 2 Ethereal accounts are created automatically with `nodemailer.createTestAccount()`
and stored as that user's senders (jobs go round-robin across them). More: `POST /api/senders/ethereal`, or `npm run seed 2` (dev user).
Read the delivered mail at https://ethereal.email/login with the sender's credentials, or via the preview URL in the worker's job result (Bull Board).

## 4. OAuth setup
- **Google login:** Google Cloud Console → OAuth client (Web). Redirect URI `http://localhost:4000/auth/google/callback`. Set `GOOGLE_CLIENT_ID/SECRET`.
- **Slack:** api.slack.com/apps → create app → enable *Incoming Webhooks* → Redirect URL must be **https** (use `ngrok http 4000`),
  set `SLACK_REDIRECT_URI=https://<tunnel>/api/slack/callback`, `SLACK_CLIENT_ID/SECRET`.
  Dashboard → *Connect Slack* → authorize a channel. *Send test* posts a live message. `PUT /api/slack {webhookUrl}` is a manual fallback.
- Set a long random `JWT_SECRET`. `AUTH_DEV_BYPASS=true` skips login for Postman (never in production).

## Environment variables
| Var | Meaning |
|---|---|
| `WORKER_CONCURRENCY` | parallel jobs per worker |
| `MIN_DELAY_BETWEEN_EMAILS_MS` | min gap between sends (**default 2000 = 2 s**) |
| `MAX_EMAILS_PER_HOUR_PER_SENDER` | hourly cap per sender (**default 100**), overridable per sender via the compose form |
| `DB_*`, `REDIS_*`, `ES_*` | connections (`DB_SSL`, `REDIS_TLS` for hosted) |

## Architecture
**Scheduling.** `POST /api/schedule` validates input, inserts one `email_jobs` row per recipient in a MySQL transaction (source of truth),
then adds a BullMQ **delayed job** per row (`delay = runAt − now`, `jobId = email-<rowId>`). Send times are `start + i × delay`, senders assigned round-robin. No cron anywhere.

**Persistence on restart.** Jobs live in Redis (AOF-enabled when using the compose file) and every row lives in MySQL. On API start `reconcileQueue()`
re-enqueues any `scheduled`/`processing` row missing from Redis. Because `jobId` is deterministic, re-adding is a no-op, so nothing is duplicated or restarted.

**Idempotency.** The worker claims a row with `UPDATE … WHERE status IN ('scheduled','processing')`; rows already `sent`/`failed` are skipped. Failed SMTP sends retry 3× with exponential backoff, then are marked `failed`.

**Concurrency.** `WORKER_CONCURRENCY` jobs run in parallel; shared state (rate counters) is in Redis, so any number of workers/instances is safe.

**Min delay.** BullMQ `limiter: {max: 1, duration: MIN_DELAY_BETWEEN_EMAILS_MS}` – queue-wide, applied across all workers.

**Hourly rate limit.** Per sender, key `rl:count:<sender>:<hourWindow>`, checked-and-incremented atomically by a Lua script (never exceeds the limit even with many workers).
When the limit is hit the job is **not failed or dropped**: it takes the next “overflow slot” (`rl:overflow:<sender>:<nextHour>`), is written back with a new `scheduled_at`,
and moved to delayed via `job.moveToDelayed`. Slot *n* lands in hour `next + ⌊n/limit⌋`, spaced by the min delay, so 1000+ jobs spread over as many future hours as needed in the order they hit the limit
(ordering is preserved per overflow queue, “as much as possible” across senders). A failed send refunds its slot. Trade-off: a window-based counter allows a burst at an hour boundary (2× limit across the boundary), simpler and cheaper than a sliding window.

**Slack.** On the first limit hit per sender per window the worker posts to the user's stored webhook. If Slack isn't connected it silently skips (no crash); connecting later takes effect immediately (read from DB each time).

**Search.** Every email is indexed in Elasticsearch (`emails`), status updated by the worker. ES is a secondary index: if it's down, scheduling/sending still work and `/api/search` returns 503.

## Features
| Area | Implemented |
|---|---|
| Backend | schedule API, BullMQ delayed jobs, MySQL persistence, restart recovery, idempotent worker, multiple Ethereal senders, configurable concurrency, min delay, per-sender hourly limit with rescheduling, Slack OAuth + live alert, Elasticsearch search, Bull Board at `/admin/queues`, Google OAuth + cookie sessions |
| Frontend | Google login, header (name/email/avatar/logout), Scheduled/Sent tabs, Compose modal (subject, body, CSV/TXT upload with detected-count, start time, delay, hourly limit), loading + empty + error states, toasts, search, auto-refresh, Connect Slack |

## Assumptions, shortcuts, trade-offs
- UI follows the assignment's layout description; I couldn't open the Figma, so colors/spacing are my own – adjust to match.
- Session = signed HttpOnly cookie (HMAC token, no extra deps). SMTP passwords are stored in plaintext (Ethereal test accounts only); encrypt for real SMTP.
- Bull Board is unauthenticated – protect it before exposing publicly.
- Rate limiting is per sender (not global); min delay is queue-wide.
- Emails are plain text.

## Demo checklist (≤5 min)
1. Schedule a few emails (1–2 min out) → show Scheduled tab. 2. Stop API + worker, restart, show they still send → Sent tab.
3. Set hourly limit to 2, schedule ~6 → show Slack alert + rescheduled times + Bull Board.

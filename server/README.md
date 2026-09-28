# Reference server

The widget is deliberately single-source: it talks to one endpoint and has
no Nightscout or Dexcom logic of its own (see
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) for why). Something has to
implement [docs/CONTRACT.md](../docs/CONTRACT.md) in front of your actual
glucose data. Two reference implementations, both reading a **Nightscout**
instance:

- **`worker/`** — a Cloudflare Worker. **Recommended default.** Free HTTPS
  with a valid certificate (Garmin refuses `http://` and self-signed certs
  outright), no host to run, deploys in a few minutes.
- **`docker/`** — a FastAPI app in a container, for self-hosting. You'll
  need to put your own TLS termination in front of it (a reverse proxy with
  Let's Encrypt, or a Cloudflare Tunnel) — Docker Compose alone doesn't give
  you a valid cert.

Dexcom Share is not implemented in either reference server. If you want it,
add a fallback the same way Nightscout is queried here — just don't put the
Dexcom account password on the watch itself; keep credentials server-side.

## Deploy the Worker

```bash
cd server/worker
npm install
wrangler login                       # once, opens a browser
wrangler secret put WATCH_TOKEN      # paste: python -c "import secrets; print(secrets.token_urlsafe(32))"
wrangler secret put NIGHTSCOUT_URL   # e.g. https://your-site.herokuapp.com (no trailing slash)
wrangler secret put NIGHTSCOUT_TOKEN # a Nightscout read-only API token
wrangler deploy
```

For local development, copy `.dev.vars.example` to `.dev.vars` (gitignored)
and run `wrangler dev`.

Your `serverUrl` for `config.local.json` is then
`https://<worker-name>.<your-subdomain>.workers.dev/api/watch/glucose`,
or your own domain if you've attached a route.

Verify it against the contract before pointing the watch at it:

```bash
WATCH_ENDPOINT_URL=https://<your-worker>.workers.dev/api/watch/glucose \
WATCH_TOKEN=<the token you set above> \
python ../../tools/check_endpoint.py
```

## Deploy the Docker variant

```bash
cd server/docker
cp .env.example .env   # fill in WATCH_TOKEN, NIGHTSCOUT_URL, NIGHTSCOUT_TOKEN
docker compose up -d --build
```

Put this behind a reverse proxy that terminates TLS with a real certificate
— Garmin will refuse to talk to it otherwise. Any of these work: Caddy
(automatic Let's Encrypt certs with a two-line Caddyfile), nginx +
certbot, or a Cloudflare Tunnel pointed at `localhost:8000`.

**`.env` changes need a container recreate** (`docker compose up -d --build`),
not a stop/start — the app reads its environment once at process start.

## Security requirements (both variants)

- **Constant-time token comparison.** Both reference implementations use
  one (`timingSafeEqual` in the Worker, `hmac.compare_digest` in the Docker
  app) so a timing side-channel can't be used to guess the token
  byte-by-byte.
- **Secrets never in version control.** Worker secrets go through
  `wrangler secret put`; Docker secrets go in a gitignored `.env`. Neither
  variant reads a token from `wrangler.jsonc` / `docker-compose.yml`.
- **Auth is header-only.** `?token=` in the query string is rejected — it
  would land in access logs and any CDN/proxy logs in front of the server.
  (Note the Nightscout *upstream* call still uses Nightscout's own
  `?token=` convention — that's between the server and Nightscout, not
  between the watch and the server, and is a separate credential from
  `WATCH_TOKEN`.)
- **Short cache (~30 s)** in front of the Nightscout calls, so a watch
  polling every 5 minutes (plus occasional on-demand fetches) doesn't
  hammer your Nightscout instance.
- **Never log the `Authorization` header or any token value.** Neither
  reference implementation logs request headers.
- For stronger rate limiting than the built-in 30 s cache provides (e.g.
  against a leaked token being hammered), add a rate-limiting rule at the
  edge — a Cloudflare dashboard rate-limiting rule for the Worker, or your
  reverse proxy's rate limiting for the Docker variant. Neither reference
  implementation includes its own beyond the cache.

## Token generation

```bash
python -c "import secrets; print(secrets.token_urlsafe(32))"
```

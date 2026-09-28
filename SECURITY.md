# Security

This widget shows glucose readings on a wrist-worn device. It is **not a
medical device** — see the warning in [README.md](README.md). That said,
the endpoint token and the reference server guard a real health-data feed,
so treat both seriously.

This repo has GitHub secret scanning and push protection enabled. If push
protection blocks a commit, that means a credential-shaped string is about
to be published — don't override it without being certain it's a
placeholder (see `config.example.json` / `.dev.vars.example` for what those
look like).

## Reporting a vulnerability

Open a private [GitHub security advisory](../../security/advisories/new) on
this repo, or open a regular issue if the finding is low-severity and does
not involve a live deployment. Please don't post exploit details (e.g. a way
to bypass token auth) in a public issue.

## Token handling

- The endpoint token authenticates as an `Authorization: Bearer <token>`
  header — **never** as a query parameter. A token in a URL ends up in
  server access logs, proxy logs, and shell history; a header does not.
- Generate tokens with `python -c "import secrets; print(secrets.token_urlsafe(32))"`.
- Sideloaded builds bake the token into the compiled `.prg`. Treat a `.prg`
  file with the same care as a credential — don't attach it to a public
  issue or share it outside your own devices.
- If a token leaks, rotate it on the server immediately. Reflashing the
  watch with a new token does **not** revoke the old one by itself — a
  watch that already has the old token stored in its persisted settings
  will keep sending it until you overwrite that setting (see
  [docs/RELEASING.md](docs/RELEASING.md) for why simply reflashing isn't
  enough).
- The reference server (`server/`) compares tokens in constant time and
  never logs the `Authorization` header — see `server/README.md`.

## Scope

This is a hobby project maintained on a best-effort basis. There's no
bug-bounty program and no guaranteed response time.

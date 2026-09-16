# 25 — Extend Token Expiry to 24h (Local Dev Only)

## Premise check

The task described the current value as already extended to 240 minutes (4 hours). That wasn't
accurate — `backend/.env`'s `ACCESS_TOKEN_EXPIRE_MINUTES` was still **30** (the original default,
matching `app/config.py`'s `access_token_expire_minutes: int = 30`) right up until this change; it
was never touched in any prior session in this conversation. Proceeded with the actually-requested
end state (24h / 1440 minutes) regardless, since that's the real goal independent of what the
starting point was believed to be.

## Change

`backend/.env`, one line:

```diff
-ACCESS_TOKEN_EXPIRE_MINUTES=30
+ACCESS_TOKEN_EXPIRE_MINUTES=1440
```

`app/config.py`'s `Settings.access_token_expire_minutes: int = 30` default (the fallback used only
if `.env` doesn't set the var) was **not** touched, per the "local `.env` only" guardrail. No other
auth logic, refresh-token expiry, JWT secret/algorithm, or any other setting was changed.

## Why a restart was required

`app/config.py`'s `get_settings()` is `@lru_cache`d — `.env` is only read once, at first call,
inside the running process. The already-running local dev server (started earlier in this
conversation) had the old value cached in memory, so a code-only edit to `.env` would not take
effect until the process restarted. Stopped and restarted the local `uvicorn app.main:app`
process (same command used in prior sessions) to pick up the new value. No other code changed as
part of this restart.

## Confirmation

Logged in fresh (`POST /api/auth/login`, existing test doctor account) after the restart and
decoded the returned access token's `exp` claim:

```
expiresAt field: 2026-09-13T10:58:08.279438Z
JWT exp claim (unix): 1789297088
hours from now: 24.0
```

Exactly 24.0 hours from issuance, confirming the new value is live.

## This is a local dev override, not for production

- Scoped to `backend/.env` only — the file this project's local dev server reads, not committed to
  version control, not a deployment/production config file.
- A 24-hour access token is appropriate **only** for unattended local validation runs (e.g. a full
  7,871-row dataset replay that can't complete inside a shorter window) where the token never
  leaves this machine. It is not an appropriate value for any deployed/production environment,
  where a long-lived access token meaningfully widens the window an intercepted token stays valid.
  Whoever deploys this app should confirm production config sets its own, much shorter, expiry
  independently of this file.

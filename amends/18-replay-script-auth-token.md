# 18 — Replay Script Auth Token

## Task

Add a `--token` argument to both `backend/validation/adapt_to_real_schema.py` and
`backend/validation/replay_blind_dataset.py`; when provided, send it as an
`Authorization: Bearer <token>` header on every request. Scope guardrail: only these two files.

## What changed

- **`adapt_to_real_schema.py`** — already had this exactly. `--token` was already an argument,
  already required alongside `--url` (the endpoint it targets, `/api/health/readings`, is behind
  `Depends(get_current_user)`), and already sent as `headers = {..., "Authorization": f"Bearer
  {args.token}"}` on every `urllib.request.Request`. No change was needed or made.
- **`replay_blind_dataset.py`** — did not have this. Added:
  - `--token` argument (optional, default `None` — this script's default `--url` target,
    `/vitals`, is a debug endpoint and doesn't require auth, so making `--token` mandatory here
    would break the existing no-auth usage).
  - `headers = {"Authorization": f"Bearer {args.token}"} if args.token else None`, computed once
    before the replay loop.
  - `requests.post(args.url, json=payload, headers=headers, timeout=5)` — passes `headers`
    (`None` when no token, which `requests` treats as "no extra headers", same as before).
  - Docstring usage examples updated with a `--token` example against the real
    `/api/health/readings` endpoint, matching `adapt_to_real_schema.py`'s existing docstring style.

## Verified

- `replay_blind_dataset.py` still parses cleanly and `--help` shows the new `--token` flag
  alongside the existing `--url`/`--speed`.
- No other files touched, per the scope guardrail.

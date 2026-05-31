---
name: managing-secrets
description: Use whenever a task touches secrets, API keys, tokens, MongoDB URIs, or env vars — rotating, adding a new key, updating a webhook, looking up where a secret is used, or wiring a new project into the rotation system. Triggers on phrases like "rotate", "new API key", "update Mailjet", ".env", "Vercel env", "secret leaked", "where does this token live", or any time the agent is about to read a .env / secrets.config.json / credentials file. Also triggers when adding a new project that uses secrets.
---

# Managing Secrets (use the `secret` tool, never read `.env` raw)

> This is a template. Copy to `~/.claude/skills/managing-secrets/SKILL.md` and
> edit the **Project aliases** section to match your `~/.config/keyrotate/_aliases.json`.

## Hard rule: never read `.env` for inspection

This machine runs **[keyrotate](https://github.com/sophie4869/keyrotate)** —
a unified secret tool at `~/bin/secret` that knows which projects exist,
what env vars each one has, where they propagate, and how each one is
rotated.

**`.env` files are write-only from the agent's perspective.** Reading them
leaks secret values into the conversation transcript and triggers an
emergency rotation. The configs at `~/.config/keyrotate/*.json` are
**values-free** and safe to read freely.

When you need to know something about a project's secrets, **use `secret`**:

| You want to know… | Run |
|---|---|
| What projects are tracked? | `secret ls` |
| What secrets does project X have? | `secret list <alias>` |
| How do I rotate KEY in project X? | `secret notes <alias> <KEY>` |
| All rotation playbooks anywhere | `secret notes` |
| Where would a value go (Vercel/GCP/Koyeb/github/local)? | check `targets` in `secret list <alias>` output |
| Current value of a list-style var (e.g. ALLOWED_ORIGINS) | `secret add` / `secret remove` reads it internally — you don't need to |

If you genuinely need a `.env` file populated locally (e.g., bootstrapping
a fresh checkout), use `secret pull <alias>` — it reads the value from the
canonical store (GCP Secret Manager) and writes the line into `.env`
without exposing it on stdout.

## If a `.env` value DID get read (emergency)

Treat any secret value that ended up in the conversation transcript, in
your scratchpad, or in any tool's stdout as **compromised**. Rotate
immediately:

```sh
secret rotate <alias> <KEY>          # for atlas-mongodb / random strategy
secret set    <alias> <KEY> --from-stdin   # for manual strategy (paste new value)
```

Tell the user what was exposed and what you rotated.

## Project aliases (the fast names)

> **Customize this section** — replace with your actual `_aliases.json` entries.

| Alias | Canonical |
|---|---|
| `ex` | example |
| (add your aliases…) | |

`secret <subcommand> <alias>` works everywhere. Bare `secret` prints
usage. Prefix substrings also resolve (`secret list myapp` matches
`myapp-staging` if unambiguous).

## Targets (where a secret physically lives)

| Target | What it does on rotate/set |
|---|---|
| `gcpSecretManager` | New version on the named GCP secret |
| `cloudRun` | Updates `--update-secrets KEY=name:latest` on each Cloud Run service in the config |
| `vercel` | DELETE + POST via Vercel REST API; sensitive type by default |
| `koyeb` | Upserts Koyeb account-level secret (manual redeploy needed to take effect) |
| `github` | `gh secret set KEY --repo …` for each repo in `.github.repo`/`.github.repos` |
| `userPassword` | Composite: bcrypt → Mongo user doc + plaintext → GitHub Actions (for test-user rotation) |
| `localEnv` | Rewrites the one matching `KEY=` line in each configured `.env` file |

Every `secret rotate` / `secret set` walks **all** targets in the secret's
`targets` array **sequentially** (no rollback — see Failure modes in the
keyrotate README). `secret rotate` is **not idempotent**: rerunning mints
*another* fresh value. On partial failure, read the value from a sink
that already succeeded (`localEnv` is usually easiest), then push it to
the remaining sinks with `secret set --value '<that-value>'` —
`secret set` only propagates, it doesn't mint. Don't manually edit
`.env`, `vercel env`, or `gcloud secrets versions add` for tracked
keys — use `secret` so all locations stay in sync.

## Common task patterns

### "Rotate the Mongo password for X"
```sh
secret rotate <alias> MONGODB_URI
```
Hits Atlas API → assembles new URI → propagates everywhere.

### "I got a new <provider> API key from the dashboard, push it"
```sh
secret set <alias> <KEY> --value '<NEW_VALUE>'
# or
secret set <alias> <KEY> --from-stdin <<< "$NEW"
```

### "Where do I rotate <provider>?"
```sh
secret notes <alias> <KEY>
```
Prints the manual UI steps (Mailjet console, Cloudflare Turnstile, GitHub
App settings, etc.).

### "Add a domain to ALLOWED_ORIGINS"
```sh
secret add <alias> ALLOWED_ORIGINS --value 'https://new-domain.com'
# Reads current value (localEnv → GCP SM → Vercel decrypted), dedupes,
# pushes the merged list everywhere.
```

### "Upgrade a Vercel project's env vars to Sensitive type"
```sh
secret vercel-upgrade <alias> --dry-run    # preview
secret vercel-upgrade <alias>              # do it
secret vercel-upgrade --all                # all configured projects
```
Heuristic only upgrades credential-shaped names (`*_SECRET`, `*_TOKEN`, `*_KEY`, `*_PASSWORD`, `*_PRIVATE`, `*_CREDENTIALS`, `MONGODB_URI`); everything else stays encrypted.

### "Add a new project to the rotation system"
1. Create `~/.config/keyrotate/<name>.json` — see `~/keyrotate/SCHEMA.md`
   for the schema and `~/keyrotate/examples/example.json` for a worked
   sample covering every strategy + target.
2. Add alias mappings to `_aliases.json` if you want short forms.
3. For each secret, decide strategy (`atlas-mongodb` / `random` / `manual`)
   and targets array.
4. Commit your configs (they're values-free).

## When the user asks "is X in the rotation system?"

Don't guess. Run:
```sh
secret list <alias> | grep -i <KEY>
```
or for cross-project:
```sh
grep -l '"<KEY>"' ~/.config/keyrotate/*.json
```

## Schema reference

Full field-by-field schema at `~/keyrotate/SCHEMA.md` (part of the public
tool repo). Read that file before inventing new fields.

## Where the tool lives

- Tool: `~/bin/secret` → symlink to `~/keyrotate/bin/secret` (clone of
  the public [github.com/sophie4869/keyrotate](https://github.com/sophie4869/keyrotate), MIT)
- Helpers: `~/bin/secret-helpers/user-password.mjs` (mongodb + bcrypt npm deps)
- Configs: `~/.config/keyrotate/*.json` (values-free, safe to commit privately)
- Schema: `~/keyrotate/SCHEMA.md`

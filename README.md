# keyrotate

> Rotate and sync secrets across every place they live — Vercel, Cloud Run, GCP Secret Manager, Koyeb, GitHub Actions, MongoDB Atlas user passwords, and local `.env` files — from a single **values-free** JSON config per project.

Two motivations, both increasingly underserved by existing "secrets management" tools.

**1. Secrets live in N places, not one.** Most tools assume one central vault with runtime fetch. Real personal infrastructure rarely looks like that: a Mongo URI lives in **four** places (Vercel env, GCP Secret Manager, Cloud Run env, local `.env`), a Mailjet key in **three** (Vercel, GitHub Actions, local), an e2e test token sometimes needs the *same* value across **eight repos' Actions secrets**. Manual rotation across all of them is a bug factory — miss one and prod stops working.

**2. AI coding agents read `.env`.** Claude Code, Cursor, Copilot, Codex — they crawl your repo for context and don't reliably tell `.env.example` apart from `.env`. The moment a real value lands in an LLM transcript, treat it as leaked: it might be in a remote log, in a chat history that gets shared, in a model's retained conversation. "Tell the agent not to read .env" is a soft constraint that drifts the moment context gets long. We need a structured way for the agent to *look at the secrets inventory without ever reading values*.

`keyrotate` answers both:

- **For (1):** declare *where each secret physically lives* in JSON. `secret rotate <project> KEY` produces a new value and pushes it to every declared sink in one command (sequentially; see the "no rollback" note below). No daemon, no vault, no SaaS — just bash + a thin wrapper around provider APIs you already have credentials for.
- **For (2):** configs are **values-free by design** (project IDs, cluster hosts, target lists — no passwords or tokens, ever). Agents can read configs freely, and *should* call the CLI rather than touch `.env`: `secret list / notes / ls` answer "what exists where, and how do I rotate it?" without ever exposing a value; `secret pull` populates a local `.env` without putting the value on stdout. There's a [matching Claude Code skill template](examples/managing-secrets.SKILL.md) that teaches an agent this protocol, and triggers emergency rotation if a value *does* end up exposed.

## Supported platforms (targets)

A "target" is somewhere a secret value physically needs to be. On `secret rotate` / `secret set`, every declared target for a secret is updated **sequentially in array order** (no pre-flight, no transaction, no rollback — see [Failure modes](#failure-modes-rerun-on-partial-failure) below):

| Target | Provider it talks to | What it does |
|---|---|---|
| `vercel` | Vercel REST API | DELETE + POST env var; defaults to `sensitive` type |
| `gcpSecretManager` | `gcloud` CLI | Add a new version to the named secret |
| `cloudRun` | `gcloud` CLI | `gcloud run services update --update-secrets KEY=name:latest` per configured service |
| `koyeb` | Koyeb REST API | Upsert account-level secret (manual redeploy still required for it to take effect) |
| `github` | `gh` CLI | `gh secret set KEY --repo …` for each repo in `.github.repo` / `.github.repos` |
| `userPassword` | Mongo + GitHub | Composite for test-user rotation: bcrypt → `users.{username}.password` in Mongo + plaintext → GitHub Actions repos |
| `ssh` | any SSH-reachable host | `ssh user@host` + `cat > /path/to/secret` + `chmod 600`. For NAS / VPS / Raspberry Pi / anywhere without a management API. Per-secret `.ssh.path` is required. |
| `localEnv` | filesystem | Rewrite the single `KEY=...` line in each configured `.env` (other lines preserved) |

Want a new target? See [Contributing](#contributing) — each is ~50 lines of bash + curl.

## Strategies (how a new value is produced)

| Strategy | Source |
|---|---|
| `atlas-mongodb` | PATCHes the Atlas user's password via Admin API, assembles a `mongodb+srv://…` URI (with optional `dbName` embedded in the path) |
| `random` | `openssl rand` → 48-char base62 by default; `length` + `encoding: hex` overrides |
| `manual` | You provide it: `--value <V>` or `--from-stdin` |

## Heads up — currently **macOS-only**

The tool reads provider credentials via macOS Keychain (`security find-generic-password`). On Linux / WSL it'll error out the moment you try to use the `atlas-mongodb` strategy. `vercel` and `koyeb` targets *do* honor env-var fallbacks (`$VERCEL_TOKEN`, `$KOYEB_TOKEN`); `github` and `gcloud` targets use their own cross-platform CLI auth and work anywhere.

Porting credential lookup to libsecret (`secret-tool`) for Linux is roughly a 30-line change in `bin/secret` — PRs welcome. If you're not on macOS and don't want to port, **you can stop reading here.**

## Prerequisites

| Required | Purpose |
|---|---|
| `bash`, `jq`, `curl`, `openssl` | the script itself |
| macOS `security` (Keychain) | reading Atlas API key (other targets have env-var fallbacks) |

| Optional (only if you use that target / strategy) | Purpose |
|---|---|
| `node` + `npm`             | install bcrypt + mongodb npm deps for the `userPassword` target |
| `gh` (logged in)           | `github` target (`gh secret set`) |
| `gcloud` (logged in)       | `gcpSecretManager` and `cloudRun` targets |

`install.sh` checks all of these and skips optional steps cleanly when their tool is missing.

## Install

```sh
git clone https://github.com/sophie4869/keyrotate ~/keyrotate
cd ~/keyrotate && bash install.sh
```

That symlinks `~/bin/secret` into `~/bin/`, runs `npm install` for the `userPassword` helper *if* node+npm are present (otherwise skipped with a note — you can still use every other target), and seeds `~/.config/keyrotate/` with the example config to copy from.

## Failure modes (recovery on partial failure)

`secret rotate` / `secret set` walks each `targets[]` entry in order and stops on the first non-`200`. There is **no pre-flight, no transaction, and no rollback** — if Vercel succeeds and Cloud Run fails on the next step, you'll have a half-rotated state where Vercel has the new value and Cloud Run still serves the old one.

`secret rotate` is **not idempotent**: every invocation generates a fresh value (Atlas PATCH + new password for `atlas-mongodb`; `openssl rand` for `random`). Re-running it after a partial failure won't push the existing new value to the remaining sinks — it'll mint *another* new value and try again.

**Recovery recipe**:

1. Read the just-written value from any sink that already succeeded — `localEnv` is the easiest (`grep '^KEY=' <projectRoot>/<env_file>`), and is usually listed first in `targets[]` for exactly this reason. For Vercel, the `/v1/.../env/{id}?decrypt=true` endpoint returns the plaintext for `encrypted` (not `sensitive`) types; `secret add` / `secret remove` already use this same fallback chain internally if you want to see it in action.
2. Push that value to the remaining sinks with `secret set <project> <KEY> --value '<value-from-sink>'` (or `--from-stdin`). This is the idempotent escape hatch — `secret set` only propagates, it doesn't mint.
3. Re-running `secret rotate` is fine too if you'd rather just rotate again from scratch — it's safe, just wasteful (extra Atlas PATCH / extra random gen) and you lose the in-flight value.

Adding pre-flight checks + ordered retries is on the backlog.

## Getting provider credentials

You only need creds for the targets you actually use. The rest of this section assumes macOS Keychain (per the heads-up above); env-var alternatives are noted per provider.

### MongoDB Atlas — for `atlas-mongodb` strategy
1. Atlas → top-left org dropdown → **Access Manager** → **Applications** → **API Keys** → **Create**.
2. Permissions: `Project Owner` on each project you want to rotate users for (or an org-level key if you'd rather have one key cover all projects).
3. Copy public + private halves into Keychain:
   ```sh
   security add-generic-password -U -s atlas-api -a public  -w '<PUBLIC_KEY>'
   security add-generic-password -U -s atlas-api -a private -w '<PRIVATE_KEY>'
   ```

### Vercel — for `vercel` target
1. https://vercel.com/account/settings/tokens → **Create Token**.
2. Scope: team if you want one token across all your team projects, account if personal-only. Expiration 1 year is reasonable.
3. ```sh
   security add-generic-password -U -s vercel-api -a token -w '<VERCEL_TOKEN>'
   ```

### Koyeb — for `koyeb` target
1. https://app.koyeb.com/user/settings/api → **Create new token**.
2. ```sh
   security add-generic-password -U -s koyeb-api -a token -w '<KOYEB_TOKEN>'
   ```

### GitHub — for `github` target
Uses `gh` CLI auth — no separate token. Just `gh auth login` once.

### GCP — for `gcpSecretManager` / `cloudRun` targets
Uses `gcloud` auth. `gcloud auth login` and make sure your account has `roles/secretmanager.admin` on the relevant project (`gcloud projects add-iam-policy-binding …`) and `roles/run.developer` for Cloud Run revision updates.

## Wiring up a new project

Open `~/.config/keyrotate/example.json` (seeded by `install.sh`) — a worked example covering every strategy and target with `_note` strings explaining the trickier secrets. Copy it to `<your-project>.json` and edit. **No field is auto-discovered** — keyrotate doesn't crawl your repo or call provider APIs to populate the config. You write the JSON once; the tool reads it forever after. (Field-by-field documentation lives in [`SCHEMA.md`](SCHEMA.md), since `.json` files can't hold comments.)

The fields fall into two buckets:

**Hand-written from things you already know** (one-time setup, no real research):
- `projectRoot` — absolute path of your local checkout
- `localEnv[].file` — relative path inside that checkout
- `vercel.envs` — usually `["production", "preview"]`
- `github.repo` / `.repos` — `owner/repo` strings
- `atlas.dbName` — the Mongo database name your app calls `client.db('…')` with
- `secrets.<KEY>.targets` — which sinks above to push to

**Hand-written from a quick dashboard lookup** (5 min per project):
- `vercel.projectId` + `vercel.orgId` — Vercel dashboard → Project Settings → General → Project ID; Team Settings → General → Team ID
- `gcpProject` + `gcpAccount` — `gcloud projects list` and `gcloud auth list`
- `cloudRun.services` + `.region` — `gcloud run services list --region <r>`
- `koyeb.appName` + `.serviceName` — Koyeb dashboard or `koyeb apps list`
- `atlas.projectId` — Atlas project URL `/v2/<projectId>/...`; or the API `GET /api/atlas/v2/groups` lists all
- `atlas.clusterHost` — Atlas → cluster → Connect → copy the `cluster0.xxxxx.mongodb.net` part of the connection string
- `atlas.dbUser` + `.authDb` — the *specific* Atlas user this entry rotates. **Required, no default.** The convention in our examples is `dbUser: "client"` + `authDb: "admin"`, but it can be any user that already exists in your Atlas project (keyrotate never creates users — it only PATCHes the password). For a cluster with multiple Atlas users (e.g. a `client` read-write user *and* a `readonly` user for analytics), declare **one secret entry per user**:
   ```jsonc
   "MONGODB_URI":          { "strategy": "atlas-mongodb",
                             "atlas": { "dbUser": "client",   ... }, "targets": [...] },
   "MONGODB_URI_READONLY": { "strategy": "atlas-mongodb",
                             "atlas": { "dbUser": "readonly", ... }, "targets": [...] }
   ```
   `secret rotate myapp MONGODB_URI` rotates only the `client` password; `secret rotate myapp MONGODB_URI_READONLY` rotates only `readonly`. The two are independent — different env-var names, optionally different `targets`.

**Per-secret choices**:
- `strategy` — `atlas-mongodb` for the Mongo URI; `random` for things you self-generate (JWT secrets, session keys, internal API tokens); `manual` for third-party API keys you got from a provider dashboard
- For `random`: `length` (default 48) and `encoding` (`base62` default, or `hex`)
- For `atlas-mongodb`: nested `atlas` block (see above)
- For `ssh` target: per-secret `ssh.path` (the absolute remote path to write to — each secret usually wants its own file)
- `manualSteps` (optional) — array of strings; surfaced by `secret notes <project> <KEY>` as the rotation playbook (provider UI link, what scopes to grant, how to verify, etc.)

**Inventory-only entries** (`"targets": []`): for credentials that live somewhere keyrotate can't reach (vendor portal, internal one-off, anything API-less). `secret list / notes` surface the entry as documentation; `secret rotate / set` succeed with a no-op propagation. See `PROVISIONING_DOC_URL` in `examples/example.json` for the pattern.

Full schema in [`SCHEMA.md`](SCHEMA.md). A worked example covering every strategy + target in [`examples/example.json`](examples/example.json).

## Quick start

Once a config is in place:

```sh
secret ls                                       # all configured projects
secret list myapp                               # secrets in myapp
secret rotate myapp JWT_SECRET                  # generate random + propagate
secret set    myapp OPENAI_API_KEY --value sk-… # propagate the value
secret add    myapp ALLOWED_ORIGINS --value 'https://new.com'   # append to a list value
secret notes  myapp OPENAI_API_KEY              # show the manual rotation playbook
```

A single `secret rotate` walks **all** declared targets for a secret — Atlas password rotation, GCP SM new version, Cloud Run revision roll, Vercel env recreation, GitHub Actions secret push, and local `.env` overwrite happen sequentially in one command. On the happy path everything stays in sync; on a sink failure, see [Failure modes](#failure-modes-rerun-on-partial-failure).

## Subcommands

```
secret ls                                       list known projects
secret list           <project>                 list secrets in a project
secret rotate         <project> <KEY>           rotate (atlas-mongodb / random)
secret set            <project> <KEY> [--value V | --from-stdin]
secret add            <project> <KEY> --value V [--separator ,]  append to delimited list
secret remove         <project> <KEY> --value V [--separator ,]  remove from delimited list
secret pull           <project> [KEY]           resync localEnv from GCP Secret Manager
secret get            <project> <KEY>           print current value to stdout (human-only — agents must not call without explicit user request; warns on non-TTY)
secret vercel-upgrade <project|--all> [--dry-run] [--encrypted|--sensitive]
                                                upgrade Vercel env vars to sensitive (heuristic by default)
secret notes          [project [KEY]]           show rotation playbooks (manualSteps)
```

`add` / `remove` read the current value via fallback chain: local `.env` → GCP Secret Manager (if configured) → Vercel single-env endpoint with `decrypt=true`. They handle the `decrypt=true` quirk that only works on `/v1/.../env/{id}` (not on the list endpoint).

## Why not [X]?

| Tool | Why this exists instead |
|---|---|
| **HashiCorp Vault** | Heavy; runtime fetch model assumes app re-reads vault on every restart. `keyrotate` is for the case where the secret value is already baked into N platforms' env stores and you need to *replace* it in each. |
| **`sops` / age** | Encrypts secrets at rest in your repo. Useful but orthogonal — once decrypted you still need to push to N platforms manually. `keyrotate` does that push. |
| **Doppler / Infisical** | Vendor-managed unified store. Great if you only have one platform; doesn't help when the same `MONGODB_URI` value has to physically exist on Vercel, Cloud Run, and a GitHub Actions secret. |
| **`vercel env pull` / `gh secret set` / `gcloud secrets versions add`** | These are the *building blocks* `keyrotate` orchestrates. |
| **Just a bash one-liner** | This used to be a 50-line bash script per project. After 13 projects, the per-target glue had grown to be the bulk of the code; this is what factoring it out looks like. |

## Provenance

This grew out of one user's home-lab dotfiles (~14 personal projects across Vercel, Cloud Run, Koyeb, NAS, and a GitHub App). The original `setup-secret.sh` was MongoDB-specific; this is the generalization. There's no SaaS, no telemetry, no daemon. It's bash, jq, curl, one node helper for bcrypt+mongo, and a JSON file per project.

## Configs aren't secrets

The config files themselves are safe to commit — they hold **structure only** (Atlas project IDs, GCP project names, Vercel project IDs, GitHub repo names, list of target sinks). The actual values (passwords, API keys) live exclusively in the configured targets and never appear in a config file. The single short-lived exception is during a rotation, where the value transits through the script's memory between gen and propagate; it's not written to any temp file and `set -euo pipefail` ensures partial failures don't leak state.

## Contributing

Issues and PRs welcome. Particularly interested in:
- Additional target types (Fly.io was dropped; Render / Heroku / Railway / AWS SSM Parameter Store would be straightforward)
- Better Atlas API integration (currently only password rotation; could do user creation, scope management)
- Cron-rotation safety checks (refuse to rotate `*_ENCRYPTION_KEY` etc. patterns)

## License

MIT — see [LICENSE](LICENSE).

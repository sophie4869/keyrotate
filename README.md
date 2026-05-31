# keyrotate

> Rotate and sync secrets across every place they live — Vercel, Cloud Run, GCP Secret Manager, Koyeb, GitHub Actions, MongoDB Atlas user passwords, and local `.env` files — from a single config file per project.

Most "secrets management" tools assume you store everything in one vault and have your apps fetch from it. Real personal infrastructure rarely looks like that: a Mongo URI lives in **four** places (Vercel env, GCP Secret Manager, Cloud Run env, local `.env`), a Mailjet key in **three** (Vercel, GitHub Actions, local), an API key sometimes also needs to be the SAME value across **eight repos' Actions secrets**. When you rotate, you have to touch every one of them in order, manually, and if you miss one your prod stops working.

`keyrotate` lets you declare *where a secret lives* in JSON, then runs `secret rotate <project> KEY` and propagates the new value to every declared sink atomically. No agent, no daemon, no vault — just a bash script + a per-project config you commit alongside your code (configs are values-free).

## Install

```sh
git clone https://github.com/sophie4869/keyrotate ~/keyrotate
cd ~/keyrotate && bash install.sh
```

That symlinks `~/bin/secret` to the tool, installs the two node deps for the `userPassword` target, and seeds `~/.config/keyrotate/` with an example config to copy from.

You'll also want some provider credentials in macOS Keychain (or env vars), per the targets you actually use:

```sh
# MongoDB Atlas Admin API (for atlas-mongodb strategy)
security add-generic-password -U -s atlas-api -a public  -w '<PUBLIC>'
security add-generic-password -U -s atlas-api -a private -w '<PRIVATE>'

# Vercel personal token (for vercel target)
security add-generic-password -U -s vercel-api -a token  -w '<TOKEN>'

# Koyeb API token (for koyeb target)
security add-generic-password -U -s koyeb-api -a token   -w '<TOKEN>'
```

GitHub target piggybacks on `gh` CLI auth (`gh auth login`). GCP target uses `gcloud` auth.

## What it does

### Strategies (how the new value is produced)

| Strategy | New value comes from |
|---|---|
| `atlas-mongodb` | PATCHes the Atlas user's password via Admin API, assembles a `mongodb+srv://…` URI |
| `random` | `openssl rand` → base62 (default) or hex |
| `manual` | You provide it: `--value <V>` or `--from-stdin` |

### Targets (where the value goes)

| Target | Action on rotate / set |
|---|---|
| `gcpSecretManager` | New version on the named GCP secret |
| `cloudRun` | `gcloud run services update --update-secrets KEY=name:latest` per service |
| `vercel` | DELETE + POST via Vercel REST API; defaults to `sensitive` type |
| `koyeb` | Upsert Koyeb account-level secret (manual redeploy still required) |
| `github` | `gh secret set KEY --repo …` for each repo in `.github.repo`/`.github.repos` |
| `userPassword` | Composite: bcrypt → MongoDB users.{username}.password + plaintext → GitHub Actions repos |
| `localEnv` | Rewrite the single `KEY=...` line in each configured `.env` file |

A single `secret rotate` runs **all** declared targets for a secret — Atlas password rotation, GCP SM new version, Cloud Run revision roll, Vercel env recreation, GitHub Actions secret push, and local `.env` overwrite happen in one command and stay in sync.

## Quick start

Drop a config into `~/.config/keyrotate/myapp.json`:

```json
{
  "projectRoot": "/Users/you/Projects/myapp",
  "vercel":   { "projectId": "prj_...", "orgId": "team_...",
                "envs": ["production", "preview"] },
  "localEnv": [{ "file": ".env" }],

  "secrets": {
    "JWT_SECRET":     { "strategy": "random", "length": 64,
                        "targets":  ["vercel", "localEnv"] },
    "OPENAI_API_KEY": { "strategy": "manual",
                        "targets":  ["vercel", "localEnv"] }
  }
}
```

Then:

```sh
secret ls                                       # all configured projects
secret list myapp                               # secrets in myapp
secret rotate myapp JWT_SECRET                  # generate random + propagate
secret set    myapp OPENAI_API_KEY --value sk-… # propagate the value
secret add    myapp ALLOWED_ORIGINS --value 'https://new.com'   # append to a list value
secret notes  myapp OPENAI_API_KEY              # show the manual rotation playbook
```

Full schema lives in [`SCHEMA.md`](SCHEMA.md). A more realistic config covering every strategy + target is in [`examples/example.json`](examples/example.json).

## Subcommands

```
secret ls                                       list known projects
secret list           <project>                 list secrets in a project
secret rotate         <project> <KEY>           rotate (atlas-mongodb / random)
secret set            <project> <KEY> [--value V | --from-stdin]
secret add            <project> <KEY> --value V [--separator ,]  append to delimited list
secret remove         <project> <KEY> --value V [--separator ,]  remove from delimited list
secret pull           <project> [KEY]           resync localEnv from GCP Secret Manager
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

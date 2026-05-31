# keyrotate config schema

One JSON file per project: `~/.config/keyrotate/<project>.json` (override with `$SECRET_CONFIG_DIR`).
Discovered automatically — no registration step.

## Top-level deploy targets (declare the ones the project has)

```jsonc
{
  "projectRoot": "/Users/you/Projects/<name>",        // absolute path; for resolving localEnv file paths
  "vercel":   { "project": "<name>",                   // human label, unused by tool
                "projectId": "prj_…",                  // Vercel dashboard → Project → Settings → Project ID
                "orgId":     "team_…",                 // Team Settings → General → Team ID
                "envs":      ["production", "preview"] },
  "gcpProject": "gcp-project-id",
  "gcpAccount": "you@example.com",
  "cloudRun":   { "services": ["service-1", "service-2"], "region": "us-central1" },
  "koyeb":      { "appName": "<app>", "serviceName": "<svc>",
                  "tokenKeychainService": "koyeb-api"    // Keychain svc name; fallback $KOYEB_TOKEN
                },
  "github":     { "repo": "owner/repo" },                // or "repos": ["owner/a", "owner/b"]
  "localEnv":   [{ "file": ".env" }],                    // array, paths relative to projectRoot
  "atlasKeychainService": "atlas-api"                    // Keychain svc name for the Atlas Admin API pair
}
```

## Per-secret

```jsonc
"secrets": {
  "MONGODB_URI": {
    "strategy":      "atlas-mongodb" | "random" | "manual",
    "gcpSecretName": "mongodb-uri",     // optional; defaults to lowercase-dash of key
    "targets":       ["gcpSecretManager", "cloudRun", "vercel", "koyeb", "localEnv"],

    // strategy=atlas-mongodb only.
    // dbName is optional but recommended — embeds /<dbName> in the URI path so
    // tools that parse the db name from the URI (e.g. mongodump in CI backup
    // workflows) work. App code that calls client.db('explicit') is unaffected.
    "atlas": { "projectId":"…", "dbUser":"client", "authDb":"admin",
               "clusterHost":"cluster0.xxx.mongodb.net",
               "dbName":"my_db_name",
               "uriParams":"retryWrites=true&w=majority" },

    // strategy=random only
    "length":   48,
    "encoding": "base62" | "hex",

    // optional override: write to a different file/key for localEnv
    "localEnv": [{ "file": "docker/.env", "key": "MONGODB_URL" }],

    // optional override: push to a different set of GitHub repos than top-level .github
    "github": { "repos": ["owner/repo-a", "owner/repo-b"] },

    // optional: rotation playbook surfaced via `secret notes <project> <KEY>`.
    // Use for secrets where rotation needs UI steps that the tool can't automate
    // (e.g. GitHub App private keys, GitHub PATs, anything from a third-party console).
    "manualSteps": [
      "Step 1 …",
      "Step 2 …"
    ]
  }
}
```

## Synthetic / shared configs

A config file may omit `projectRoot` and act as a holder for secrets shared across multiple repos (e.g. `_shared-monitoring.json`). Such configs only use `github` (or other targets that don't need a project root).

## Strategies

| strategy | how value is produced |
|---|---|
| `atlas-mongodb` | PATCH Atlas user password → assemble `mongodb+srv://…` |
| `random`        | `openssl rand` → base62 (default) or hex |
| `manual`        | take from `--value <V>` or `--from-stdin` (no `secret rotate`; use `secret set`) |

## Targets

| target | how value is propagated |
|---|---|
| `gcpSecretManager` | new version on the named GCP secret |
| `cloudRun`         | for each service: `gcloud run services update --update-secrets KEY=name:latest` |
| `vercel`           | for each env in `vercel.envs`: DELETE + POST via Vercel REST API (`sensitive` type) |
| `koyeb`            | Koyeb REST API: upsert **account-level secret** by name (service `koyeb.serviceName` then needs a manual redeploy to consume it) |
| `github`           | `gh secret set KEY` to repos listed in `.github.repo`/`.github.repos` (top-level) or per-secret `.secrets[K].github.repos` |
| `userPassword`     | **Composite.** bcrypt the value and write to an auth-backend Mongo user, then push the plaintext to GitHub Actions repos. See `secrets[K].userPassword` block (`projectRef`, `username`, `githubRepos`, optional `dbName`/`collection`/`bcryptRounds`). |
| `localEnv`         | rewrite the single matching `KEY=` line in each `localEnv[].file` (other lines preserved) |

Targets are processed **sequentially in array order**, not transactionally. If a later target fails after earlier ones succeeded, state is partially updated — fix the cause and rerun the same `secret rotate/set` command (it's idempotent).

## CLI

```
secret ls
secret list           <project>
secret rotate         <project> <KEY>           # atlas-mongodb / random
secret set            <project> <KEY> [--value V | --from-stdin]
secret add            <project> <KEY> --value V [--separator ,]    # append to delimited list
secret remove         <project> <KEY> --value V [--separator ,]    # remove from delimited list
secret pull           <project> [KEY]           # resync localEnv from GCP Secret Manager
secret notes          [project [KEY]]           # show rotation playbooks (manualSteps)
secret vercel-upgrade <project|--all> [--dry-run] [--encrypted|--sensitive] [--all-keys]
```

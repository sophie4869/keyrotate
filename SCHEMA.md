# secret-rotate config schema

One JSON file per project: `~/.config/secret-rotate/<project>.json`.
Looked up by `proj <name> secret` (and the bare CLI).

## Top-level deploy targets (declare the ones the project has)

```jsonc
{
  "projectRoot": "/Users/sophiebi/Projects/<name>",   // for resolving localEnv file paths
  "vercel":   { "project": "<name>",
                "projectId": "prj_…",
                "orgId":     "team_…",
                "envs":      ["production", "preview"] },
  "gcpProject": "gcp-project-id",
  "gcpAccount": "you@example.com",
  "cloudRun":   { "services": ["service-1", "service-2"], "region": "us-central1" },
  "koyeb":      { "appName": "<app>", "serviceName": "<svc>" },   // token from $KOYEB_TOKEN
  "github":     { "repo": "owner/repo" },                          // or "repos": ["...", "..."]
  "localEnv":   [{ "file": ".env" }],                              // array, paths relative to projectRoot
  "atlasKeychainService": "atlas-api"
}
```

## Per-secret

```jsonc
"secrets": {
  "MONGODB_URI": {
    "strategy":      "atlas-mongodb" | "random" | "manual",
    "gcpSecretName": "mongodb-uri",     // optional; defaults to lowercase-dash of key
    "targets":       ["gcpSecretManager", "cloudRun", "vercel", "koyeb", "localEnv"],

    // strategy=atlas-mongodb only
    // dbName is optional but recommended — embeds /<dbName> in the URI path so
    // tools that parse the db from the URI (e.g. mongodump in CI backup
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
| `manual`        | take from `--value <V>` or `--from-stdin` (no rotate command, only set-secret) |

## Targets

| target | how value is propagated |
|---|---|
| `gcpSecretManager` | new version on `secretName` |
| `cloudRun`         | for each service: `gcloud run services update --update-secrets KEY=secretName:latest` |
| `vercel`           | for each env in `vercel.envs`: rm+add via `vercel env` (or REST) |
| `koyeb`            | Koyeb API: update service env var with new value |
| `github`           | `gh secret set` to repos listed in `.github.repo`/`.github.repos` (top-level) or per-secret `.secrets[K].github.repos` |
| `userPassword`     | **Composite.** bcrypt the value and write to an auth-backend Mongo user, then push the plaintext to GitHub Actions repos. See `secrets[K].userPassword` block (`projectRef`, `username`, `githubRepos`, optional `dbName`/`collection`/`bcryptRounds`). |
| `localEnv`         | rewrite the single line in each `localEnv[].file` |

## CLI

```
secret-rotate <project> <KEY>                # produce new value per strategy + propagate
secret-set    <project> <KEY> --value <V>    # only propagate (for manual)
secret-set    <project> <KEY> --from-stdin
secret-pull   <project> [KEY]                # local-only resync from GCP Secret Manager (or Vercel)
```

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
                "envs":      ["production", "preview"],
                "autoRedeploy": true                   // optional, default true. When prod is in envs and a
                                                       // rotate/set successfully updates Vercel env, trigger
                                                       // a redeploy of the latest READY prod deployment so
                                                       // running functions actually pick up the new value.
                                                       // Set to false for projects where you'd rather
                                                       // redeploy manually.
              },
  "gcpProject": "gcp-project-id",
  "gcpAccount": "you@example.com",
  "cloudRun":   { "services": ["service-1", "service-2"], "region": "us-central1" },
  "koyeb":      { "appName": "<app>", "serviceName": "<svc>",
                  "tokenKeychainService": "koyeb-api"    // Keychain svc name; fallback $KOYEB_TOKEN
                },
  "github":     { "repo": "owner/repo" },                // or "repos": ["owner/a", "owner/b"]
  "ssh":        { "host": "10.0.0.5", "user": "deploy",  // ssh target host (per-secret .ssh.path is required)
                  "keyFile": "~/.ssh/id_keyrotate",      // optional; ssh default keys otherwise
                  "port": 22 },                          // optional
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
    // dbUser is the *specific* Atlas user this entry rotates; required, no
    // default. The user must already exist (keyrotate never creates users —
    // it only PATCHes the password). For multiple Atlas users on the same
    // cluster, declare one secret entry per user (each with its own env-var
    // name) and rotate them independently.
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

    // optional: after primary propagation, push the SAME value to other
    // projects' deploy targets. Use when one shared secret has to live in
    // multiple projects (e.g. a JWT signing key issued by an auth server
    // and verified by N other services with HS256). Each entry temporarily
    // switches the secret tool's CFG context to the named project's config
    // and reruns the listed target subset there. The other project's
    // gcpProject / vercel / cloudRun / localEnv blocks supply the destination
    // metadata; the secret name (KEY) stays the same.
    "crossProjectPropagate": [
      { "project": "downstream-a", "targets": ["gcpSecretManager", "cloudRun", "localEnv"] },
      { "project": "downstream-b", "targets": ["vercel", "localEnv"] }
    ],

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

A config file may omit `projectRoot` and act as a holder for secrets shared across multiple repos (convention: prefix the filename with `_`, e.g. `_shared.json`). Such configs only use `github` (or other targets that don't need a project root).

## Strategies

| strategy | how value is produced |
|---|---|
| `atlas-mongodb` | PATCH Atlas user password → assemble `mongodb+srv://…` |
| `random`        | `openssl rand` → base62 (default) or hex |
| `manual`        | take from `KEY=value` shorthand, `--value <V>`, or `--from-stdin` (no `secret rotate`; use `secret set`) |

## Targets

| target | how value is propagated |
|---|---|
| `gcpSecretManager` | new version on the named GCP secret |
| `cloudRun`         | for each service: `gcloud run services update --update-secrets KEY=name:latest` |
| `vercel`           | for each env in `vercel.envs`: DELETE + POST via Vercel REST API (`sensitive` type) |
| `koyeb`            | Koyeb REST API: upsert **account-level secret** by name (service `koyeb.serviceName` then needs a manual redeploy to consume it) |
| `github`           | `gh secret set KEY` to repos listed in `.github.repo`/`.github.repos` (top-level) or per-secret `.secrets[K].github.repos` |
| `userPassword`     | **Composite.** bcrypt the value and write to an auth-backend Mongo user, then push the plaintext to GitHub Actions repos. See `secrets[K].userPassword` block (`projectRef`, `username`, `githubRepos`, optional `dbName`/`collection`/`bcryptRounds`). |
| `ssh`              | `ssh user@host` + `cat > <secrets[K].ssh.path>` + `chmod 600`. Top-level `.ssh` declares the host/user/keyFile/port; per-secret `.ssh.path` is required (each secret usually has its own file on the remote). For SSH-reachable hosts that don't have an API (NAS, VPS, Raspberry Pi). |
| `localEnv`         | rewrite the single matching `KEY=` line in each `localEnv[].file` (other lines preserved). Each entry takes optional `mode` (chmod after write; default `"600"`) — set `"640"` to share with a sibling user via group membership. `file` starting with `/` is treated as absolute; relative is resolved against `projectRoot` (allows one canonical file outside any project root, e.g. `/Users/Shared/secrets.env`). |

Targets are processed **sequentially in array order** — no pre-flight, no transaction, no rollback. `secret rotate` is **not idempotent**: each invocation mints a fresh value. On partial failure, read the value back from a sink that succeeded (`localEnv` is usually easiest) and push it to the remaining sinks with `secret set --value '<that-value>'` — `secret set` only propagates, never mints.

**Inventory-only entries**: a secret may declare `"targets": []` and rely entirely on `manualSteps`. `secret list/notes` will surface it; `secret rotate/set` will succeed with a no-op propagation. Useful for credentials that live somewhere keyrotate can't reach (vendor portals, internal one-offs).

## CLI

```
secret ls
secret list           <project>
secret rotate         <project> <KEY> [KEY...]                                                # atlas-mongodb / random
secret set            <project> <KEY=V | KEY --value V | KEY --from-stdin> [more pairs...]
secret add            <project> <KEY> --value V [--separator ,]                               # append to delimited list
secret remove         <project> <KEY> --value V [--separator ,]                               # remove from delimited list
secret pull           <project> [KEY]                                                         # resync localEnv from GCP Secret Manager
secret get            <project> <KEY>                                                         # print current value to stdout (human-only; warns on non-TTY)
secret notes          [project [KEY]]                                                         # show rotation playbooks (manualSteps)
secret vercel-upgrade <project|--all> [--dry-run] [--encrypted|--sensitive] [--all-keys]
```

**Multi-key invocations on `rotate` / `set` batch the post-write Vercel redeploy**: every Vercel project touched (including via `crossProjectPropagate`) gets one redeploy at the end of the run, deduplicated by projectId. For `set`, the three pair forms (shorthand `KEY=V`, explicit `--value`, and `--from-stdin`) can mix freely in one invocation — `--from-stdin` and the interactive prompt remain single-key only.

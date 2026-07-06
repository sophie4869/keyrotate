# Changelog

All notable changes to `keyrotate` are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [SemVer](https://semver.org/).

## [Unreleased]

## [0.1.0] — 2026-06-17

First tagged release. `keyrotate` is production-ready for the maintainer's own use across ~14 projects; API is not frozen yet, expect additive changes in 0.x.

### Added

- **Core**: `secret rotate`, `secret set`, `secret add`, `secret remove`, `secret pull`, `secret get`, `secret list`, `secret ls`, `secret notes`, `secret vercel-upgrade`.
- **Strategies**: `atlas-mongodb` (mints Atlas passwords via Admin API + assembles URI), `random` (base62 / hex), `manual`.
- **Targets**: `gcpSecretManager`, `cloudRun`, `vercel`, `koyeb`, `github`, `userPassword` (composite: bcrypt→Mongo + plaintext→GH Actions), `ssh`, `localEnv`.
- **Multi-key `rotate` / `set`**: `secret rotate proj K1 K2` or `secret set proj K1=V1 K2=V2` — Vercel redeploy is deferred to end-of-run and deduplicated by projectId. Rotating N keys that hit the same Vercel project = 1 redeploy, not N.
- **`KEY=value` shorthand for `set`** — mixable with `--value V` and `--from-stdin` in the same invocation.
- **`--targets a,b` scoped push** on both `rotate` and `set`. Skips other declared targets AND skips `crossProjectPropagate`. Use for partial-failure recovery.
- **`crossProjectPropagate`**: a secret owned by one config can also land in other configs' targets (e.g. a JWT signing secret in an auth service, verified in N downstream services).
- **`prop_vercel` auto-redeploy**: after a successful Vercel env write, trigger a production redeploy so the new value goes live (Vercel doesn't hot-reload).
- **`prop_koyeb` upsert + auto-redeploy**: proper GET-by-name → PUT-by-id / POST flow (Koyeb's API keys resources by ID not name), then triggers a service redeploy so the new value is picked up (Koyeb also doesn't hot-reload).
- **`prop_gcp_secret_manager` auto-grant `secretAccessor`**: on first-time secret creation, grants the Cloud Run runtime SA read access.
- **`prop_ssh` multi-path + envKey**: `ssh.paths[]` accepts multiple destinations per secret; each entry can have an `envKey` that does in-place `KEY=` line update on a remote `.env`-style file (useful for docker-compose `env_file` paths on a NAS / VPS). Non-envKey entries write the raw value to a single file.
- **`prop_local_env` per-entry `mode`**: default `600` preserves prior behavior; set `"mode": "640"` to share the file with a sibling group user (e.g. a `bot` user running cron).
- **Absolute paths in `localEnv`**: entries whose `file` starts with `/` are taken as-is; relative paths still resolve against `projectRoot`.
- **`gcpSecretName` override**: explicit GCP SM secret name (default: derived from the key). Namespace-safe when default names would collide.
- **Inventory-only entries**: `"targets": []` + `manualSteps` for credentials that live somewhere `keyrotate` can't reach (vendor portals).
- **[managing-secrets skill template](examples/managing-secrets.SKILL.md)** — Claude Code skill teaching an agent to never read `.env` directly, always route via `secret list / notes / pull`. Includes emergency-rotate protocol when a value does leak.

### Fixed

- **Koyeb**: was `POST`-only, failing with `"already exists"` when the secret existed. Now upserts via GET→PUT-by-id / POST.
- **SSH**: `mv`-across-filesystems broke on Synology / cross-mount setups. Now uses in-place `>` write, only requires write perm on the target file (not the parent dir), and best-effort `chmod 600`.
- **`--targets` flag position**: previously only accepted immediately after the project alias; now accepted anywhere in the args.

### Documented

- README: motivations, target matrix, provider-cred setup, failure modes, quick start, no-rollback semantics, wiring a new project, subcommands.
- SCHEMA.md: full JSON schema — top-level fields, strategies, targets, cross-project propagation, `userPassword` composite, `localEnv` overrides.
- Examples: `example.json` (a fully-annotated skeleton), `_aliases.json` template, `managing-secrets.SKILL.md`.
- Explicit callouts throughout: **currently macOS-only** (macOS Keychain for provider creds), **not idempotent** on `rotate` (each invocation mints fresh; use `set` for repropagation).

[Unreleased]: https://github.com/sophie4869/keyrotate/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/sophie4869/keyrotate/releases/tag/v0.1.0

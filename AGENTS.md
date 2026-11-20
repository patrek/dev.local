# AGENTS.md

Instructions for AI coding agents (Claude Code, Codex, Copilot, Cursor and others) working in this repository or driving the stack it manages.

## What this project is

Dev.Local runs a local Docker development stack behind Traefik. Each service is described by one file, `profiles/<name>.yml`. Scripts turn the profiles and `config.yml` into `docker-compose.yml` and `traefik/dynamic.yml`, then start and stop the services.

- Every script exists twice: Bash (`*.sh`, Linux and macOS) and PowerShell (`*.ps1`, Windows). **Bash is the reference**; the PowerShell script must behave the same.
- `just` is the common entry point on every platform. Prefer `just <recipe>` over calling a script directly.
- User-facing text, code comments and the documentation are in French. Commit messages are in English.

## Driving the stack

All commands run from the repository root and never ask a question, except the ones listed under [Do not run](#do-not-run).

| Goal | Command |
|------|---------|
| State of every service | `just status --json` |
| List the profiles | `just profiles --json` |
| Start the always-active services | `just start` |
| Start Docker profiles too | `just start-profile api,ui` |
| Stop everything | `just stop` |
| Stop, then start again | `just restart` |
| Run a one-off command in a service | `just run <service> <command...>` |
| Validate the profiles | `just validate-profiles --json` |
| Check whether the generated files are stale | `just generate --dry-run --json` |
| Regenerate `docker-compose.yml` and `traefik/dynamic.yml` | `just generate` |
| Add a service | `just add-profile --name <name> --image <image> [options]` |
| Names of the secret variables the profiles need | `./manage-profiles.sh list-secrets` |

Exit code `0` means success, anything else is a failure. With `--json`, stdout holds only the JSON document; messages for humans go to stderr. Without `--json`, output is French prose with colours: check the exit code and do not parse the text.

Do not follow logs with `just logs`: it never returns. Use `docker compose logs --tail 100 <service>`.

Routes: a service with Traefik enabled answers on `http://localhost:8080<prefix>`. Container logs are browsable at `http://localhost:8080/logs`.

### JSON outputs

`just status --json` lists every service of `docker-compose.yml`, started or not:

```json
[{"service": "api", "state": "running", "health": "healthy"},
 {"service": "worker", "state": "not_created", "health": null}]
```

`state` is the Docker state (`running`, `exited`, `restarting`, ...) or `not_created` when the service has no container. `health` is `healthy`, `unhealthy`, `starting`, or `null` when the service has no health check.

`just profiles --json` lists one object per profile file, with defaults applied:

```json
[{"name": "api", "file": "profiles/api.yml", "description": "API", "enabled": true,
  "always_active": false, "docker_profile": "backend", "expose_ports": false,
  "image": "nginx:alpine", "traefik_enabled": true, "url": "http://localhost:8080/api"}]
```

A profile with `always_active: false` starts only with `just start-profile <docker_profile>`. A profile with `enabled: false` is not in `docker-compose.yml` at all.

`just validate-profiles --json` exits `1` when `valid` is `false`. Messages are in French:

```json
{"valid": false, "validated": 3,
 "errors": [{"profile": "api", "message": "Champ 'docker-compose.image' manquant ou vide"}],
 "warnings": []}
```

`just generate --dry-run --json` writes nothing and reports each generated file as `new`, `changed` or `unchanged`. It exits `1` when the profiles are invalid.

```json
[{"file": "docker-compose.yml", "status": "changed"},
 {"file": "traefik/dynamic.yml", "status": "unchanged"}]
```

### Adding or changing a service

To add a service without any prompt:

```bash
just add-profile --name api --image nginx:alpine --description "API" \
    --docker-port 8000 --traefik-prefix /api --docker-profile backend \
    --env LOG_FORMAT=json --secret API_TOKEN
```

`--name` and `--image` are required. Run `./manage-profiles.sh --help` for every option. The command creates `profiles/<name>.yml` and regenerates the Compose and Traefik files (`--no-generate` skips that). It fails if the profile already exists.

To change a service, edit its profile file, then:

1. `just validate-profiles --json`
2. `just generate`
3. `just restart`, or `just start-profile <profile>`

The profile format is described by `schemas/profile.schema.json`, and `config.yml` by `schemas/config.schema.json`. `profiles/example.yml` is a commented model. The schema covers the format of one file; `just validate-profiles` is the authority and also checks duplicate keys, container names and host ports across profiles.

Rules worth knowing before writing a profile:

- `always_active: false` (the default) requires a `docker_profile`.
- Ports listed in `docker-compose.ports` are published only when `expose_ports: true`, and on `127.0.0.1` unless the entry names an IP. By default a service is reachable through Traefik only.
- Never edit `docker-compose.yml` or `traefik/dynamic.yml`: they are generated and not versioned.

## Do not run

| Command | Reason |
|---------|--------|
| `just secrets-view`, `sops -d secrets.env` | Prints decrypted secrets. |
| `just secrets-edit`, `./manage-profiles.sh init-secrets`, `sync-secrets` | Open an editor or ask for confirmation. Ask the user to run them. |
| `just aws-sso`, `just ecr-login`, `just jfrog-login` | Open a browser or ask for credentials. Ask the user to run them. |
| `just menu`, `just add-profile` without options | Interactive. |
| `just clean` | Deletes the containers **and volumes** of every profile. Only on explicit request. |

Never read, print or commit `.env`, `secrets.env` in decrypted form, `age-key.txt` or `*.agekey`. Decrypted secrets must never be written to disk.

`just stop` and `just restart` affect every running service of the stack. When testing a change to the scripts, work in a scratch copy of the repository, not against the user's running stack.

## Changing the scripts

- Change the Bash script first, then make the same change in its PowerShell twin. `tests/compare-shells.sh` compares the generated files, the detected secrets and the `--json` outputs of both.
- `*.ps1` files are UTF-8 with BOM and CRLF line endings; `*.sh` files use LF. Keep them that way (see `.gitattributes`).
- YAML is read through `yq` (mikefarah v4, see `lib/yq.sh`) in Bash and through the `powershell-yaml` module in PowerShell. Do not parse YAML with `grep` or `sed`.
- Generated ports must stay bound to `127.0.0.1` by default; the tests check it.

Checks to run before proposing a change:

```bash
just test                  # Bash tests: generation, validation, --json outputs
just lint                  # ShellCheck through Docker
tests/compare-shells.sh    # PowerShell tests and Bash/PowerShell parity (needs pwsh and powershell-yaml)
pipx run check-jsonschema --schemafile schemas/profile.schema.json profiles/*.yml tests/fixtures/profiles/*.yml
```

After an intended change to the generated output, refresh the reference files with `tests/run-tests.sh --update` and review the diff. A new validation rule needs a fixture in `tests/fixtures/invalid/` whose first line is `# expect: <message>`. CI (`.github/workflows/ci.yml`) runs all of the above plus PSScriptAnalyzer.

Update `README.md` and `CHEATSHEET.md` when a command or an option changes. Each document has one role, listed in the README under "Documentation Complète".

## Git

- Conventional Commits, in English: `feat(profiles): add JSON output to list`.
- Never commit to `main`; open a pull request from a `feat/` or `fix/` branch.

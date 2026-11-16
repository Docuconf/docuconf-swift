# shop: a docuconf example

One program that runs as two workloads, a `web` server and a queue `worker`, configured by a contract written by hand
and loaded in [contract-first mode](../../README.md#contract-first-mode) (`ContractDocument`). It shows three parts of
the spec:

- **roles** (SPEC §4.9): `DOCUCONF_ROLE` picks the role, and an input marked with roles is required only in those. The
  web server needs `ALLOWED_ORIGINS`, the worker needs `QUEUES`, and neither needs the other's.
- **`requiredIf`** (SPEC §4.2.1): `LOG_SCHEMA_URL` is required while `LOG_FORMAT` is `json`, and the
  `webhook-signing-key` file while `WEBHOOKS_ENABLED` is `true` (in the worker; the web server never reads it).
- **an included fragment** (SPEC §4.8): the contract includes `otel@1`, whose `OTEL_*` variables are inline in `vars`
  and checked at boot like the app's own.

It has no server, database or queue. The package depends on nothing but the SDK in this repository, as
`.package(name: "docuconf-swift", path: "../..")`, and uses only its Foundation-only `DocuconfCore` library.

- [`Sources/Shop/ShopConfig.swift`](Sources/Shop/ShopConfig.swift) loads the contract, validates the environment
  against it and types the values (`ShopConfig`); [`main.swift`](Sources/Shop/main.swift) prints one line and exits 0,
  or lists every problem and exits 1.
- [`Tests/ShopTests/ShopTests.swift`](Tests/ShopTests/ShopTests.swift) runs the test matrix below (`swift test`).
- [`contract.json`](contract.json) is the contract, the same in every docuconf SDK's shop example. The app reads it
  from the current directory at every start (`Shop path/to/contract.json` reads another copy):

  ```swift
  let contract = try ContractDocument(json: Data(contentsOf: URL(fileURLWithPath: "contract.json")))
  let values = try await contract.load(environment: ProcessInfo.processInfo.environment)
  ```

- [`contract.cue`](contract.cue) is the same contract in CUE, for `cue vet` and the platform. It is generated:
  `./contract-cue.sh` rewrites it from `contract.json`, and CI fails if it is out of date.

`@Env` and `@FileInput` declarations cannot declare roles, `requiredIf` or fragments yet, so this example is
contract-first, unlike [`Examples/Orders`](../Orders), whose contract is exported from its declaration.

| Input | Type | Rules |
|---|---|---|
| `DOCUCONF_ROLE` | enum | `web` or `worker`; required |
| `DATABASE_URL` | url | secret, required, scheme `postgres` or `postgresql` |
| `PORT` | int | `web` only; 1–65535, default `8080` |
| `ALLOWED_ORIGINS` | list of strings (comma-separated) | `web` only; required |
| `QUEUES` | list of strings (comma-separated) | `worker` only; required |
| `WEBHOOKS_ENABLED` | bool | `worker` only; default `false` |
| `LOG_FORMAT` | enum | `text` or `json`; default `text` |
| `LOG_SCHEMA_URL` | url | scheme `https`; required when `LOG_FORMAT` is `json` |
| `OTEL_*` | from `otel@1` | optional; `OTEL_EXPORTER_OTLP_PROTOCOL` is one of `grpc`, `http/protobuf`, `http/json` |
| `webhook-signing-key` (file) | text | `worker` only; secret, at `/etc/shop/webhooks/signing.key`, at least 32 characters; required when `WEBHOOKS_ENABLED` is `true` |

Lists are comma-separated on the wire, the contract's default encoding. Files are read under `DOCUCONF_FILE_ROOT` when
it is set.

## Run it

Swift 6.2 or later:

```sh
cd Examples/Shop
export DATABASE_URL=postgres://shop@db:5432/shop
DOCUCONF_ROLE=web ALLOWED_ORIGINS=https://shop.example swift run Shop
DOCUCONF_ROLE=worker QUEUES=default,mail swift run Shop
```

prints (after the build output)

```text
shop web: port 8080, origins https://shop.example
shop worker: queues default,mail, webhooks off
```

The worker prints `webhooks on` when `WEBHOOKS_ENABLED=true` and the signing key is at
`$DOCUCONF_FILE_ROOT/etc/shop/webhooks/signing.key`. The queues it prints come from the typed `ShopConfig`, not the raw
environment.

## When the configuration is wrong

With JSON logs but no `LOG_SCHEMA_URL`, the worker does not start. Every problem is reported at once on standard
error, with a stable error code, no backtrace and never a secret value, and the process exits with status 1:

```console
$ DOCUCONF_ROLE=worker QUEUES=default LOG_FORMAT=json swift run Shop
docuconf: 1 configuration problem:
  - LOG_SCHEMA_URL [missing_required]: is required when LOG_FORMAT is "json"
$ echo $?
1
```

Contract-first mode returns the problems as a `ConfigurationError` and leaves reporting to the app, so this example
prints them and exits; unlike `Docuconf.loadOrExit`, it does not write `/dev/termination-log`.

## Test matrix

[`ShopTests.swift`](Tests/ShopTests/ShopTests.swift) runs every case (`swift test`), each from
`DATABASE_URL=postgres://shop@db:5432/shop` with a fresh, empty `DOCUCONF_FILE_ROOT`. A failing case must report
exactly the one problem listed. Another test checks that a bad `DATABASE_URL` is reported without its value.

| # | Env (plus the base) | Expected |
|---|---|---|
| 1 | `DOCUCONF_ROLE=web ALLOWED_ORIGINS=https://shop.example` | ok: `shop web: port 8080, origins https://shop.example` |
| 2 | `DOCUCONF_ROLE=worker QUEUES=default,mail` | ok: `shop worker: queues default,mail, webhooks off`; the worker needs no `ALLOWED_ORIGINS` |
| 3 | `DOCUCONF_ROLE=web` | `ALLOWED_ORIGINS` `missing_required` |
| 4 | `QUEUES=default` (no role) | `DOCUCONF_ROLE` `missing_required`, and nothing else |
| 5 | `DOCUCONF_ROLE=cron` | `DOCUCONF_ROLE` `not_in_enum`, and nothing else |
| 6 | `DOCUCONF_ROLE=worker QUEUES=default LOG_FORMAT=json` | `LOG_SCHEMA_URL` `missing_required`: `is required when LOG_FORMAT is "json"` |
| 7 | as 6, plus `LOG_SCHEMA_URL=https://logs.example/v1.json` | ok |
| 8 | `DOCUCONF_ROLE=worker QUEUES=default WEBHOOKS_ENABLED=true`, no key file | `webhook-signing-key` `file_missing`: `..., and is required when WEBHOOKS_ENABLED is true` |
| 9 | as 8, with a 38-character key at `etc/shop/webhooks/signing.key` under the root | ok: `shop worker: queues default, webhooks on` |
| 10 | `DOCUCONF_ROLE=web ALLOWED_ORIGINS=https://shop.example WEBHOOKS_ENABLED=true` | ok: the key file belongs to the worker |
| 11 | `DOCUCONF_ROLE=web ALLOWED_ORIGINS=https://shop.example OTEL_EXPORTER_OTLP_PROTOCOL=carrier-pigeon` | `OTEL_EXPORTER_OTLP_PROTOCOL` `not_in_enum`: fragment variables are checked at boot |

[`smoke.sh`](smoke.sh) builds the app and runs the real process for cases 1, 2 and 6, checking standard output,
standard error and the exit status. CI runs both.

## Generated docs

[`CONFIG.md`](CONFIG.md) (for developers), [`CONFIG.agents.md`](CONFIG.agents.md) (for AI agents) and
[`docs.json`](docs.json) (the docs model both are rendered from) are generated from `contract.cue` by the `docuconf` CLI
from [docuconf-go](https://github.com/docuconf/docuconf-go). Never edit them by hand. After changing `contract.json`,
regenerate `contract.cue` and the docs (CI runs each docs command with `--check` in place of `-o`):

```sh
./contract-cue.sh
docuconf docs contract.cue -o CONFIG.md
docuconf docs contract.cue --format agents -o CONFIG.agents.md
docuconf docs contract.cue --format model -o docs.json
```

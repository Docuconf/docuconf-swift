# orders: a docuconf example

A small HTTP service that declares its configuration with docuconf on top of
[swift-configuration](https://github.com/apple/swift-configuration). It shows:

- the declaration (`OrdersConfig` in [`Sources/Orders/main.swift`](Sources/Orders/main.swift)): types, ranges, an
  enum, lists, a duration and secrets, each with a description;
- boot validation that reports every problem at once and never prints the secret;
- the exported contract, [`contract.cue`](contract.cue), that the platform checks before it deploys.

The service has three routes: `GET /healthz` returns `ok`, `GET /config` returns the loaded configuration as JSON
with the secrets shown as `"***"`, and `POST /webhooks/payments` accepts a payment webhook signed with a key in
`WEBHOOK_KEYS` (see [Rotate a key](#rotate-a-key)). The HTTP server is a few lines of POSIX sockets
([`HTTPServer.swift`](Sources/Orders/HTTPServer.swift)), so the example depends on nothing but the SDK and
swift-crypto (for the webhook HMAC); a real service would use Hummingbird or Vapor (see the main README's recipes).
The package depends on the SDK in this repository as `.package(name: "docuconf-swift", path: "../..")`; the
`name:` makes it build whatever the checkout's folder is called (a fork, or a ZIP download's `docuconf-swift-main`).

| Variable | Type | Rules |
|---|---|---|
| `PORT` | int | 1–65535, default `8080` |
| `LOG_LEVEL` | enum | `debug`, `info`, `warn`, `error`; default `info` |
| `DATABASE_URL` | url | secret, required, scheme `postgres`, at most 2048 characters |
| `ALLOWED_ORIGINS` | list of strings | comma-separated, at least 1 item; default `http://localhost:3000` |
| `REQUEST_TIMEOUT` | duration | number of seconds, 1–300 (`1s`–`5m`), default `30` |
| `WORKER_COUNT` | int | 1–64, default `4` |
| `WEBHOOK_KEYS` | list of strings | comma-separated, secret, optional; 1–2 keys of 32–256 characters each |

Each is read from swift-configuration's key (`log.level`), which `EnvironmentVariablesProvider` maps to the
upper-cased name (`LOG_LEVEL`).

## Run it

Swift 6.2 or later:

```sh
cd Examples/Orders
DATABASE_URL=postgres://orders:secret@localhost:5432/orders PORT=8080 swift run Orders
curl localhost:8080/healthz
curl localhost:8080/config
```

## A bad environment

With `PORT=0` and no `DATABASE_URL`, the service does not start:

```console
$ PORT=0 swift run Orders
docuconf: 2 configuration problems:
  - PORT [out_of_range]: is below min 1 (got "0")
  - DATABASE_URL [missing_required]: is required but not set (Postgres connection string for the orders database)
$ echo $?
1
```

In Kubernetes the same text goes to `/dev/termination-log`, so `kubectl describe pod` shows it.

`./smoke.sh` checks both cases: it builds the app, starts it with a valid environment, checks `/healthz`, that
`/config` hides the secrets and that webhooks signed with either key are accepted, then starts it with `PORT=0` and
no `DATABASE_URL` and checks it fails with `missing_required` and `out_of_range`, and with an empty webhook key.

## Rotate a key

`WEBHOOK_KEYS` is a key set: `POST /webhooks/payments` accepts a body whose `X-Signature` header is the hex
HMAC-SHA256 of the body under any key in the list ([`Webhook.swift`](Sources/Orders/Webhook.swift)). A variable is
read once, at start, so a new key reaches the service only when the pods restart; with two keys valid at once, no
webhook is turned away while that happens:

1. Add the new key as the second item (`old,new` in the Secret), and roll out.
2. Switch the sender to the new key.
3. Remove the old key (`new`), and roll out.

It is declared as `@Env("webhook.keys", ..., .secret, .items(1...2), .itemLength(32...256)) var webhookKeys:
[String]?`, so a trailing comma or a truncated key stops the service at boot instead of locking out the sender:

```console
$ DATABASE_URL=postgres://orders:pw@localhost:5432/orders WEBHOOK_KEYS=old-webhook-key-0123456789abcdef0123, swift run Orders
docuconf: 1 configuration problem:
  - WEBHOOK_KEYS [out_of_range]: item 1 is 0 characters, shorter than 32
```

In a values file, the key set is a `secretKeyRef`:

```yaml
WEBHOOK_KEYS: # a key set: one Secret key holding "old,new" while rotating
  secretKeyRef: {name: orders-webhooks, key: keys}
```

[`WebhookTests.swift`](Tests/OrdersTests/WebhookTests.swift) walks through a rotation (`swift test`), and
`smoke.sh` posts webhooks signed with both keys.
[SPEC section 6.1](https://github.com/docuconf/docuconf-go/blob/main/spec/SPEC.md#61-rotation) covers rotation in
general.

## Export the contract

```sh
swift run Orders docuconf-export --out contract.cue
```

This reads no environment, so it runs anywhere. CI re-exports the contract, fails if it differs from the committed
`contract.cue`, and runs `cue vet -c` on it against the meta-schema.

## Generated docs

[`CONFIG.md`](CONFIG.md), the reference for developers, and [`CONFIG.agents.md`](CONFIG.agents.md), the rules and
facts AI agents need, are generated from `contract.cue` by the `docuconf` CLI from
[docuconf-go](https://github.com/docuconf/docuconf-go), through the docs model in [`docs.json`](docs.json). Never
edit them by hand; regenerate them after exporting the contract (CI fails if they are out of date):

```sh
docuconf docs contract.cue -o CONFIG.md
docuconf docs contract.cue --format agents -o CONFIG.agents.md
docuconf docs contract.cue --format model -o docs.json
```

## Deploy

The platform never runs the app to learn what it needs: it reads `contract.cue`. `docuconf vet` checks the values a
deployment supplies against the contract before anything is applied, and `docuconf render` turns them into the
container's environment (here, `REQUEST_TIMEOUT` rendered as a number of seconds). Both come from the
[docuconf CLI](https://github.com/docuconf/docuconf-go/tree/main/cmd/docuconf); the
[Helm chart](https://github.com/docuconf/docuconf-go/tree/main/helm/docuconf) in docuconf-go does the same at
`helm install` time.

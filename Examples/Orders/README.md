# orders: a docuconf example

A small HTTP service that declares its configuration with docuconf on top of
[swift-configuration](https://github.com/apple/swift-configuration). It shows:

- the declaration (`OrdersConfig` in [`Sources/Orders/main.swift`](Sources/Orders/main.swift)): types, ranges, an
  enum, a list, a duration and a secret, each with a description;
- boot validation that reports every problem at once and never prints the secret;
- the exported contract, [`contract.cue`](contract.cue), that the platform checks before it deploys.

The service has two routes: `GET /healthz` returns `ok`, and `GET /config` returns the loaded configuration as JSON
with the secret shown as `"***"`. The HTTP server is a few lines of POSIX sockets
([`HTTPServer.swift`](Sources/Orders/HTTPServer.swift)), so the example depends on nothing but the SDK; a real
service would use Hummingbird or Vapor (see the main README's recipes). The package depends on the SDK in this
repository as `.package(name: "docuconf-swift", path: "../..")`; the `name:` makes it build whatever the checkout's
folder is called (a fork, or a ZIP download's `docuconf-swift-main`).

| Variable | Type | Rules |
|---|---|---|
| `PORT` | int | 1–65535, default `8080` |
| `LOG_LEVEL` | enum | `debug`, `info`, `warn`, `error`; default `info` |
| `DATABASE_URL` | url | secret, required, scheme `postgres` |
| `ALLOWED_ORIGINS` | list of strings | comma-separated, at least 1 item; default `http://localhost:3000` |
| `REQUEST_TIMEOUT` | duration | number of seconds, 1–300 (`1s`–`5m`), default `30` |
| `WORKER_COUNT` | int | 1–64, default `4` |

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

`./smoke.sh` checks both cases: it builds the app, starts it with a valid environment, checks `/healthz` and that
`/config` hides the secret, then starts it with `PORT=0` and no `DATABASE_URL` and checks it fails with
`missing_required` and `out_of_range`.

## Export the contract

```sh
swift run Orders docuconf-export --out contract.cue
```

This reads no environment, so it runs anywhere. CI re-exports the contract, fails if it differs from the committed
`contract.cue`, and runs `cue vet -c` on it against the meta-schema.

## Deploy

The platform never runs the app to learn what it needs: it reads `contract.cue`. `docuconf vet` checks the values a
deployment supplies against the contract before anything is applied, and `docuconf render` turns them into the
container's environment (here, `REQUEST_TIMEOUT` rendered as a number of seconds). Both come from the
[docuconf CLI](https://github.com/docuconf/docuconf-go/tree/main/cmd/docuconf); the
[Helm chart](https://github.com/docuconf/docuconf-go/tree/main/helm/docuconf) in docuconf-go does the same at
`helm install` time.

# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately, through GitHub's private vulnerability reporting: open the repository's
**Security** tab and choose **Report a vulnerability**
([direct link](https://github.com/docuconf/docuconf-swift/security/advisories/new)). Do not open a public issue, pull
request or discussion for a suspected vulnerability.

Include what you can of:

- the affected version (the package version or commit, and whether the `TLS` trait is on);
- what an attacker can do, and what they need first;
- steps or a minimal declaration, contract, environment or file that reproduces it.

We work on the fix in a private security advisory, credit you in it unless you prefer otherwise, and publish the
advisory when a fixed release is out.

## Response targets

| | |
|---|---|
| Acknowledge the report | within 3 business days |
| First assessment (confirmed or not, severity) | as soon as we can reproduce it, and we keep you updated in the advisory |
| Fix | released as a patch to the supported version, then the advisory is published |

## Supported versions

The package is released as git tags that SwiftPM resolves (see [RELEASING.md](RELEASING.md)). Security fixes go to
the latest minor release, as a new patch release.

**During the beta, only the latest release is supported.** Upgrade to it to get a fix.

## Scope

In scope:

- the `Docuconf` and `DocuconfCore` libraries: loading and validating configuration, the file, certificate and
  keystore checks, contract-first mode, and the contract export, for example a value that passes validation but
  should not, or a secret that reaches an error message, a log, the termination log or an exported contract.

Out of scope: the example applications under [`Examples`](Examples), vulnerabilities in dependencies (such as
swift-configuration, swift-crypto, swift-certificates or Yams) that docuconf does not make reachable (report those
upstream), and issues in a platform or cluster that only arise from its own misconfiguration. The docuconf CLI, the
specification and the other language SDKs live in their own repositories and follow their own policies.

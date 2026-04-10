# Security Policy

## Supported versions

Orbit is a fast-moving desktop app. Security fixes are only guaranteed for:

| Version | Supported |
| --- | --- |
| `main` | Yes |
| Latest GitHub release | Yes |
| Older releases | No |

## Reporting a vulnerability

Please do **not** open a public issue for a security problem.

Report vulnerabilities through one of these channels:

- GitHub Security Advisories for this repository
- Email: `opensource@orbitcodex.org`

Please include:

- affected Orbit version or commit
- macOS version
- a short reproduction path
- whether the issue involves desktop permissions, screen capture, auth reuse, local key storage, or bundled runtime behavior

We will aim to:

- acknowledge receipt within 3 business days
- provide an initial triage status within 7 business days
- coordinate a fix and disclosure timeline with you when the report is valid

## Security posture

- Orbit ships with no bundled third-party telemetry in the open-source build.
- Orbit has no hosted backend of its own.
- Cloud voice API keys are stored in the macOS Keychain.
- Orbit is a direct-download macOS app that requires full desktop permissions to function.

Because Orbit intentionally works with elevated desktop access, reports involving unauthorized screen capture, credential exposure, command execution, auth/session leakage, or installer tampering should be sent privately first.

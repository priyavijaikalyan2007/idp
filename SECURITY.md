# Security Policy

## Scope

This repository builds and operates the YourApp Keycloak IdP: a customized Keycloak 26.x container, Java SPI providers, OAuth/OIDC/MCP configuration, Cloud Run deployment metadata, and operational scripts.

Security reports may involve authentication bypass, OAuth/OIDC flow flaws, dynamic client registration abuse, token leakage, tenant or scope escalation, secret exposure, Keycloak configuration drift, Cloud Run/IAM exposure, or denial-of-service risks against the identity broker.

## Supported Versions

Only the currently deployed Keycloak 26.x patch line is supported. Patch releases should be treated as security-relevant by default and applied promptly after testing.

## Reporting a Vulnerability

Do **not** open a public GitHub issue for security vulnerabilities.

Use GitHub Security Advisories for this repository, or contact the maintainers privately if advisory access is unavailable. Include one finding per report when possible.

## What To Include

- Description of the vulnerability.
- Affected component, realm, endpoint, script, or configuration.
- Preconditions and required privileges.
- Reproduction steps with safe test data.
- Impact: what an attacker can read, modify, bypass, mint, exhaust, or escalate.
- Evidence such as sanitized logs, request/response metadata, screenshots, or commit references.
- Suggested remediation, if known.

Do not include live secrets, access tokens, refresh tokens, private keys, database dumps, or plaintext credentials in the report body. If secret material was exposed, identify where and coordinate rotation privately.

## Response Priorities

- **Critical:** authentication bypass, token forgery, signing-key exposure, admin privilege escalation, production credential exposure.
- **High:** tenant isolation failure, scope escalation, DCR abuse enabling token delivery to attacker-controlled destinations, exploitable IdP denial of service.
- **Medium:** hardening gaps, missing rate limits, sensitive metadata exposure, unsafe defaults that require additional preconditions.
- **Low:** documentation or defense-in-depth issues with limited exploitability.

## Operational Expectations

- Production secrets belong in GCP Secret Manager or equivalent; never in source, scripts, logs, dumps, or GitHub Actions variables unless intentionally scoped and protected.
- Keycloak database dumps are sensitive artifacts and must be encrypted at rest, stored outside the repository, and tightly permissioned.
- Security fixes should be tested with `./test.sh` and relevant `./smoke.sh` checks before deployment.

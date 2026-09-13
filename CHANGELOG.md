# Changelog

All notable changes to the `snapnedit` Ruby gem are documented here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
gem adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-13

First release. Ruby >= 3.2, standard library only, no runtime dependencies.

### Added

- `Snapnedit::Client` — `run`, `upload`, `create_job`, `get_job`,
  `wait_for_job`, `download_result`, `list_operations`.
- Bring-your-own-storage: `{ url: … }` job inputs, `presigned-put` and `saved`
  delivery destinations, account-default destinations with `destination: nil`
  opt-out, and `delete_after_delivery` (`download` may be `nil`).
- `client.destinations` — `list`, `create`, `update`, `delete`, `test`,
  `presign_upload`, with snake_case keyword arguments mapped to the api's
  camelCase.
- `client.embed` — `create_session` (publishable key) and `create_token`
  (secret key).
- `client.designs` — `create` and `render` (PNG/JPEG/WebP/AVIF/PDF bytes).
- `Snapnedit::Webhooks.verify` and `.construct_event` — HMAC-SHA256 signature
  verification with constant-time comparison and an optional freshness window,
  checked against the shared cross-language test vector.
- `Snapnedit::Error` with `code`/`status`, `Snapnedit::TimeoutError`,
  `Snapnedit::SignatureVerificationError`, and `Snapnedit::ErrorCodes` covering
  every code the api can return.
- `Snapnedit::Operations` — the 17 operation ids, their credit costs and which
  ones require a mask.
- Automatic retries with exponential backoff, jitter and `Retry-After` support
  on `429`/`5xx`/network failures, for idempotent requests only.
- Injectable HTTP adapter (`Client.new(http:)`) for tests and custom transports.
- RBS signatures in `sig/`.
- Full SDK conformance suite: all 24 scenarios of the monorepo's
  `test/conformance/scenarios.json`.

[Unreleased]: https://github.com/Snap-N-Edit/sdk-ruby/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Snap-N-Edit/sdk-ruby/releases/tag/v0.1.0

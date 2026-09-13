# Changelog

All notable changes to the `snapnedit` Ruby gem are documented here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
gem adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-09-13

### Added

- `Client#usage` — `GET /usage`: jobs, credits, cache hits, deliveries and
  embed sessions over a date range, bucketed along one dimension
  (`group_by:` `day` / `key` / `origin` / `operation` / `source`) and
  filterable by `key_id:`, `origin:`, `operation:` and `source:`. `from:` /
  `to:` accept a `Time`, a `Date` or an ISO-8601 `String` (a bare
  `"YYYY-MM-DD"` means that whole UTC day).
- `UsageReport`, `UsageTotals`, `UsageSeriesEntry`, `UsageKey` and
  `UsageFacts`, plus `Snapnedit::Usage::{GROUP_BY, SOURCES, UNATTRIBUTED}`.
  `UsageReport#bucket("upscale")` looks one series entry up by key;
  `UsageKey#remaining_today` gauges a publishable key against its daily cap.
- The `usage.query` conformance scenario. The suite now implements all **25**
  scenarios of `test/conformance/scenarios.json`.

- `Job#credit_cost`, `Job#cached?` and `Job#delivery_only?` — the per-job usage
  attribution `POST /jobs` and `GET /jobs/{id}` now echo, with
  `RunResult#credit_cost` / `RunResult#cached?` delegating to the final job. A
  body without them (an older deployment) reads as unbilled and uncached.

### Changed

- A cache hit creates a NEW job row: `POST /jobs` answers `200` with a new
  `jobId`, the SAME `outputAssetId` as the job whose result it reuses, and
  `cached: true` / `creditCost: 0` — so usage can count requests separately
  from model runs. `Job#cache_hit?` now reads that `cached` flag and only falls
  back to the `200` status, which makes it true for a polled job too.

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

[Unreleased]: https://github.com/Snap-N-Edit/sdk-ruby/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/Snap-N-Edit/sdk-ruby/releases/tag/v0.1.1
[0.1.0]: https://github.com/Snap-N-Edit/sdk-ruby/releases/tag/v0.1.0

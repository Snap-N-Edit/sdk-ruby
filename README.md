# snapnedit — Ruby SDK

The official Ruby client for the [snapnedit](https://snapnedit.com) AI
image-editing API: upload an image, run an operation, get the result.

Standard library only — `net/http`, `json`, `openssl`. **No runtime
dependencies.** Ruby >= 3.2.

```ruby
require "snapnedit"

client = Snapnedit::Client.new(api_key: ENV.fetch("SNAPNEDIT_API_KEY"))

result = client.run(Snapnedit::Operations::REMOVE_BACKGROUND, "cat.jpg")
result.write("cat-cutout.png")

# ...or step by step, if you want the job id in between:
asset = client.upload("cat.jpg")
job   = client.create_job(Snapnedit::Operations::UPSCALE, asset.asset_id, params: { factor: "4" })
done  = client.wait_for_job(job.id)
File.binwrite("cat-4x.png", client.download_result(done))
```

---

## Install

```sh
gem install snapnedit
```

> **RubyGems push is pending.** Until the first release lands on rubygems.org,
> install from source:
>
> ```ruby
> # Gemfile
> gem "snapnedit", git: "https://github.com/Snap-N-Edit/sdk-ruby"
> ```

```ruby
# Gemfile, once published
gem "snapnedit", "~> 0.1"
```

Get an API key from your [snapnedit dashboard](https://snapnedit.com/dashboard).
`Snapnedit::Client` talks to `https://snapnedit.com/api` by default; pass
`base_url: "http://localhost:8787"` for a local stack.

---

## The client

| Method | What it does |
| --- | --- |
| `run(operation, input, **opts)` | Upload → create → poll → download, in one call. Returns a `RunResult`. |
| `upload(path_or_io, mime: nil)` | `POST /uploads` → presigned PUT → `POST /uploads/:id/confirm`. Returns an `Upload`. |
| `create_job(operation, input, params:, destination:)` | `POST /jobs`. Returns immediately with a `Job`. |
| `get_job(job_id)` | One poll of `GET /jobs/:id`. |
| `wait_for_job(job_id, poll_interval:, timeout:)` | Polls until the job is terminal *and* its delivery has settled. |
| `download_result(job)` | Fetches the result bytes from the signed url. |
| `list_operations` | `GET /operations` — the catalog, including each operation's params JSON Schema. Public. |
| `usage(from:, to:, group_by:, …)` | `GET /usage` — jobs, credits and embed sessions over a range, bucketed. Returns a `UsageReport`. |
| `destinations` | Saved storage destinations: `list`, `create`, `update`, `delete`, `test`, `presign_upload`. |
| `embed` | `create_session` (publishable key → token) and `create_token` (secret key → scoped token). |
| `designs` | `create` (compile a design spec) and `render` (server-side render to bytes/PDF). |
| `Snapnedit::Webhooks.verify` / `.construct_event` | Webhook signature verification. |

`input` for `run` is a **file path**, any **IO** (`File`, `StringIO`), or
`{ url: "https://…" }` to have the server fetch the bytes itself. `input` for
`create_job` is an **asset id** (or the `Upload` that produced it) or
`{ url: … }`.

Idempotent requests (`GET`s, the presigned PUT, `confirm`, `PATCH`, `DELETE`)
are retried with exponential backoff and jitter on `429`, `5xx` and network
failures, honouring `Retry-After`. `POST /jobs`, `POST /destinations` and
`POST /embed/tokens` are never retried — replaying them could bill twice.

---

## Rails

An initializer:

```ruby
# config/initializers/snapnedit.rb
SNAPNEDIT = Snapnedit::Client.new(
  api_key: Rails.application.credentials.dig(:snapnedit, :api_key),
  read_timeout: 30
)
```

Kick a job off from a background job rather than a request, and store the id:

```ruby
class RemoveBackgroundJob < ApplicationJob
  def perform(photo)
    job = SNAPNEDIT.create_job(
      Snapnedit::Operations::REMOVE_BACKGROUND,
      SNAPNEDIT.upload(photo.file.download_path).asset_id
    )
    photo.update!(snapnedit_job_id: job.id)
  end
end
```

…and let the webhook tell you when it finished. **Verify the raw body before
parsing it** — a re-serialized body will not match the signature:

```ruby
# config/routes.rb
post "/webhooks/snapnedit", to: "snapnedit_webhooks#create"

# app/controllers/snapnedit_webhooks_controller.rb
class SnapneditWebhooksController < ActionController::API
  def create
    payload   = request.raw_post
    signature = request.headers["X-Snapnedit-Signature"]
    secret    = Rails.application.credentials.dig(:snapnedit, :webhook_secret)

    event = Snapnedit::Webhooks.construct_event(payload, signature, secret, tolerance: 300)

    case event["type"]
    when "job.succeeded" then Photo.finish!(event.dig("data", "jobId"), event.dig("data", "download"))
    when "job.failed"    then Photo.fail!(event.dig("data", "jobId"), event.dig("data", "errorCode"))
    end

    head :ok
  rescue Snapnedit::SignatureVerificationError
    head :bad_request
  end
end
```

`Snapnedit::Webhooks.verify(payload, signature, secret, tolerance: 300)`
returns a boolean instead of raising, if you prefer to branch. It never raises
for a malformed header, a bad signature or a stale timestamp.

Skip Rails' CSRF/param wrapping for that route (`ActionController::API` above
already does), and make sure nothing rewrites the body before you read it.

---

## Bring your own storage

The bytes never have to pass through your process.

**Input from a url** — the server fetches it (https only, no redirects, 30s
timeout, size-capped, account-only):

```ruby
result = client.run(
  Snapnedit::Operations::UPSCALE,
  { url: presigned_get_url_for("originals/cat.png") },
  params: { factor: "2" }
)
```

**Output to a PUT you signed yourself:**

```ruby
client.run(
  Snapnedit::Operations::REMOVE_BACKGROUND, "cat.png",
  destination: {
    type: "presigned-put",
    url: my_presigned_put_url,
    headers: { "content-type" => "image/png" }
  }
)
# => RunResult#downloaded? == false — the bytes are in your bucket, not here.
```

When you name an explicit destination and the delivery succeeds, `run` skips
the download by default. A delivery that **failed** still downloads, so you are
never left empty-handed — and `status: "succeeded"` with
`delivery.status == "failed"` is a real, correct combination. Pass
`download: true` to get both, or `download: false` to skip it always.

### Saved destinations

Register an S3-compatible bucket once and name it by id; snapnedit signs the
PUT itself at delivery time, so a rotated credential applies to jobs that are
already queued.

```ruby
dest = client.destinations.create(
  name: "exports",
  provider: "cloudflare-r2",          # or aws-s3 / backblaze-b2 / s3-compatible
  bucket: "my-bucket",
  account_id: ENV.fetch("R2_ACCOUNT_ID"),
  key_prefix: "snapnedit/",
  access_key_id: ENV.fetch("R2_KEY_ID"),
  secret_access_key: ENV.fetch("R2_SECRET"),
  is_default: true
)

client.destinations.test(dest.id).ok?          # => true — a real round trip
client.run(Snapnedit::Operations::UPSCALE, "cat.png", destination: dest)
```

Objects land at `<key_prefix>YYYY/MM/DD/<jobId>.<ext>`.

* **`is_default: true`** makes every job that names no destination land there.
* **`destination: nil`** on one job opts out of that default. Omitting
  `destination:` entirely means "use my default, if I have one" — the two are
  *not* the same.
* **`delete_after_delivery: true`** drops snapnedit's own copy once your bucket
  confirms. `Job#download` is then `nil` and `RunResult#downloaded?` is `false`
  — the only copy is at `delivery.bucket` / `delivery.key`.

A one-shot signed PUT into your own bucket, for a client-side export:

```ruby
signed = client.destinations.presign_upload(dest.id, ext: "png", content_type: "image/png")
# signed.url, signed.headers, signed.key, signed.expires_at
```

The secret access key is never echoed by any response — only
`access_key_id_last4`. Neither is a presigned `inputUrl`, destination `url` or
its `headers`: those are bearer credentials for your bucket, and the api treats
them as secrets in motion.

---

## What a job cost

Every job — from `create_job`, `get_job`, `wait_for_job`, and delegated on
`RunResult` — reports its own attribution, the same three facts `GET /usage`
aggregates:

| | |
| --- | --- |
| `job.credit_cost` | Credits actually debited. 0 for a free operation, a cache hit, a delivery-only clone, or an unmetered website job. Debited at creation, refunded in full if the job ends `failed`. |
| `job.cached?` | The result came out of the cache: no model ran, nothing was billed. `job.cache_hit?` reads this flag (falling back to the `200`-not-`202` status for a job you polled rather than created). |
| `job.delivery_only?` | The row exists only to deliver an already-cached result to your bucket — cached, free, and still worth polling for `delivery`. |

```ruby
job = client.create_job(Snapnedit::Operations::UPSCALE, asset.asset_id)
job.credit_cost   # => 2
job.cached?       # => false

again = client.create_job(Snapnedit::Operations::UPSCALE, asset.asset_id)
again.cached?     # => true — a new job id, the same result, billed 0
again.credit_cost # => 0
```

---

## Usage and credits

`client.usage` is `GET /usage`: what the account ran, what it cost and where it
came from, bucketed along **one** dimension at a time. No arguments means the
last 30 days grouped by day.

```ruby
report = client.usage(group_by: "operation", from: Date.today - 7)

report.from                      # => "2026-09-06T00:00:00.000Z" (an instant, not a day)
report.totals.jobs               # => 128  — REQUESTS, cache hits included
report.totals.credits            # => 214  — what was actually debited
report.totals.cache_hits         # => 31   — served from cache, billed nothing
report.totals.active_sessions    # => 4    — embed sessions seen in the range

report.series.first.key          # => "upscale"
report.bucket("upscale").credits # => 96
```

| Argument | |
| --- | --- |
| `from:` / `to:` | A `Time`, a `Date`, or an ISO-8601 `String`. A bare `"2026-09-01"` is that whole UTC day. Defaults to the last 30 days; a range over 366 days is `invalid_input`. |
| `group_by:` | One of `Snapnedit::Usage::GROUP_BY` — `day` (zero-filled, oldest first), `key`, `origin`, `operation`, `source`. Everything but `day` is ordered busiest first. |
| `key_id:` / `origin:` / `operation:` / `source:` | Filters. `source:` is one of `Snapnedit::Usage::SOURCES` (`api`, `embed`, `session`, `anonymous`). |

`report.keys` is the cap gauge — every live api key on the account with what it
has spent **today**, whatever range you asked for:

```ruby
report.keys.each do |key|
  next unless key.capped?
  warn "#{key.name}: #{key.used_today}/#{key.daily_credit_limit} today" if key.remaining_today < 10
end
```

Two things to know before writing an assertion against it:

* **A cache hit still creates a job.** One row per *request*, so `totals.jobs`
  counts what you asked for and `totals.cache_hits` says how many of those ran
  no model. `POST /jobs` on a hit therefore answers a **new** job id with the
  **same** `output_asset_id` as the job whose result it reuses — and the job
  itself says so: `job.cached? == true`, `job.credit_cost == 0`.
* **An embed token sees only its own key.** `key_id:` is forced to it and
  `report.keys` comes back empty — a page-scoped credential must not become an
  account-wide reporting one.

---

## Errors

Every failure raises `Snapnedit::Error`, which carries a machine-readable
`#code` and the HTTP `#status`. **Branch on `code`, never on `message`** —
messages are human text and change.

```ruby
begin
  client.run(Snapnedit::Operations::UPSCALE, "cat.png", params: { factor: "4" })
rescue Snapnedit::Error => e
  case e.code
  when Snapnedit::ErrorCodes::PAYMENT_REQUIRED then top_up_credits!
  when Snapnedit::ErrorCodes::RATE_LIMITED     then retry_later!
  when Snapnedit::ErrorCodes::INVALID_INPUT    then report("bad params: #{e.message}")
  else raise
  end
rescue Snapnedit::TimeoutError
  # polling ran out of budget; the job may still finish — poll `get_job` later
end
```

| Code | Meaning |
| --- | --- |
| `invalid_input` | Bad params, an unknown param key, or a missing `maskAssetId`. |
| `unsupported_mime` | Not PNG, JPEG or WebP. |
| `too_large` | Over the size ceiling. |
| `not_found` | No such job/destination **on your account** — never `403`, so an id is not an existence oracle. |
| `input_fetch_failed` | An `inputUrl` could not be fetched. Terminal, never retried, credits refunded. |
| `provider_failed` / `provider_exhausted` | The model failed. |
| `rate_limited` | Slow down. Retried automatically for idempotent calls. |
| `bot_check_failed` | Bot protection (browser sessions only). |
| `unauthorized` | No usable credential, or an unknown/revoked one. |
| `forbidden` | Authenticated, but not allowed — e.g. an anonymous caller supplying `inputUrl`. |
| `payment_required` | Out of credits. |
| `internal` | Anything else, including a network failure on this side. |

`Snapnedit::ErrorCodes::ALL` is the full, closed set. A code this gem has not
been updated for degrades to `internal` rather than raising while parsing the
error.

A job that reaches `failed` raises with **the job's own** `errorCode`.
`Snapnedit::TimeoutError` is a client-side poll timeout, not an api response,
so it carries no code or status.

---

## Operations

`Snapnedit::Operations::ALL` — 17 ids. Credits are charged at job-creation
time; an identical resubmission is a **free cache hit** (`Job#cached?`) — a new
job id, the same `output_asset_id`, and `credit_cost == 0`.

| Constant | Id | Credits | Mask |
| --- | --- | --- | --- |
| `REMOVE_BACKGROUND` | `remove-background` | 1 | |
| `UPSCALE` | `upscale` | 2 | |
| `UNBLUR` | `unblur` | 1 | |
| `COLORIZE` | `colorize` | 1 | |
| `STYLE_TRANSFER` | `style-transfer` | 2 | |
| `RETOUCH` | `retouch` | 1 | |
| `BEAUTIFY` | `beautify` | 1 | |
| `MAGIC_ERASER` | `magic-eraser` | 2 | required |
| `GENERATIVE_FILL` | `generative-fill` | 3 | required |
| `REMOVE_WATERMARK` | `remove-watermark` | 2 | required |
| `AI_DENOISE` | `ai-denoise` | 1 | |
| `REPLACE_SKY` | `replace-sky` | 2 | |
| `RELIGHT` | `relight` | 2 | |
| `REPLACE_BACKGROUND` | `replace-background` | 2 | |
| `STRIP_METADATA` | `strip-metadata` | 1 | |
| `AUTO_REMOVE_WATERMARK` | `auto-remove-watermark` | 2 | |
| `RESIZE_IMAGE` | `resize-image` | **0** (free) | |

Each operation's `params` are validated against a **strict** JSON Schema — an
unrecognized key is a `400`, not an ignored field. Read the schemas from the
catalog:

```ruby
client.list_operations.each do |op|
  puts "#{op.id}: #{op.params_json_schema.dig("properties")&.keys&.join(", ")}"
end
```

Mask-guided operations need a second image. `run` uploads it and sets
`params[:maskAssetId]` for you:

```ruby
client.run(Snapnedit::Operations::MAGIC_ERASER, "photo.png", mask: "mask.png")
```

Some operations are deployment-gated (`generative-fill`, `relight`,
`auto-remove-watermark` ship before their models do); the catalog is the
authority on what a given deployment will actually run.

---

## Development

```sh
bundle config set --local path vendor/bundle
bundle install

bundle exec rubocop
bundle exec rspec                    # unit specs — no network, injected HTTP adapter
bundle exec rspec --tag conformance  # the 25-scenario SDK conformance suite
gem build snapnedit.gemspec
```

The conformance suite spawns `node scripts/conformance-server.mjs` from the
snapnedit monorepo — the **real** api and worker over an in-memory store — and
implements every scenario in `test/conformance/scenarios.json`, one `describe`
per scenario id. It is skipped automatically outside a monorepo checkout. See
[`docs/sdk-conformance.md`](https://github.com/Snap-N-Edit/snapnedit) for what
it covers.

RBS signatures for the public API ship in `sig/`.

---

## About this repository

This gem is **mirrored from the snapnedit monorepo** (`sdks/ruby`), history
intact. File issues and PRs here; they are merged upstream.

* API reference: <https://snapnedit.com/docs/api-reference>
* OpenAPI document: <https://snapnedit.com/api/openapi.json>
* Other official SDKs: [`sdk`](https://github.com/Snap-N-Edit/sdk) (TypeScript),
  [`embed`](https://github.com/Snap-N-Edit/embed),
  [`mcp`](https://github.com/Snap-N-Edit/mcp)

MIT licensed — see [LICENSE](LICENSE).

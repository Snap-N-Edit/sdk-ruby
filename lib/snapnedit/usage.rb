# frozen_string_literal: true

module Snapnedit
  # The vocabulary of `GET /usage`: the dimensions a series can be bucketed
  # along, and the ways a job can have arrived.
  #
  # @see Client#usage
  module Usage
    # Dimensions `group_by:` accepts. One at a time — the api never crosses two.
    GROUP_BY = %w[day key origin operation source].freeze

    # How a job was requested, as the api persists it: an `sk_` key (`api`), an
    # embedded editor (`embed`), a signed-in website visitor (`session`), or a
    # visitor with no account (`anonymous`). The last two are never billed, so
    # they contribute jobs but no credits.
    SOURCES = %w[api embed session anonymous].freeze

    # The series key a bucket lands under when it has no value for the grouped
    # dimension — an `sk_` job has no origin, a website job has no api key.
    UNATTRIBUTED = "none"
  end

  # The seven counters every usage bucket carries, shared by {UsageTotals} and
  # each {UsageSeriesEntry}.
  #
  # They count REQUESTS, not model runs: a cache hit is one more {#jobs} and
  # one more {#cache_hits}, billed nothing.
  class UsageFacts < Model
    # @return [Integer] jobs created in this bucket, cache hits included.
    def jobs = count("jobs")

    # @return [Integer] credits actually debited. A free operation, a cache hit
    #   and an unmetered website/anonymous job all contribute 0.
    def credits = count("credits")

    # @return [Integer] jobs served from the result cache instead of a model.
    def cache_hits = count("cacheHits")

    # @return [Integer] jobs whose operation costs 0 credits.
    def free = count("free")

    # @return [Integer] jobs that ended `failed` (and were refunded).
    def failed = count("failed")

    # @return [Integer] jobs whose result was successfully PUT to a storage
    #   destination.
    def delivered = count("delivered")

    # @return [Integer] jobs whose delivery failed. The job itself may still
    #   have succeeded — a failed delivery never fails a job.
    def delivery_failed = count("deliveryFailed")

    private

    # A counter the api omitted reads as 0 rather than nil: every field here is
    # a count, and "absent" and "none" mean the same thing for a count.
    def count(key)
      @raw[key] || 0
    end
  end

  # `totals` — the whole range, undivided, plus the two embed-session counts
  # that no series bucket can always carry.
  class UsageTotals < UsageFacts
    # @return [Integer] embed sessions STARTED in the range.
    def sessions = count("sessions")

    # @return [Integer] embed sessions last seen within the range, whenever
    #   they started.
    def active_sessions = count("activeSessions")
  end

  # One bucket of `series`: a day, an api key, an origin, an operation or a
  # source, depending on the `group_by:` that was asked for.
  class UsageSeriesEntry < UsageFacts
    # @return [String] the dimension value — a `YYYY-MM-DD`, an api key id, an
    #   origin, an operation id or a source. {Usage::UNATTRIBUTED} when the row
    #   had no value for the grouped dimension.
    def key = @raw["key"]

    # @return [String] a human label for {#key}: the key's NAME for
    #   `group_by: "key"`, the key itself otherwise.
    def label = @raw["label"]

    # @return [Integer] embed sessions started in this bucket. Always 0 for
    #   `group_by: "operation"` / `"source"`, which sessions have no dimension
    #   for — read {UsageTotals#sessions} instead.
    def sessions = count("sessions")
  end

  # One row of the key cap gauge: an api key on the account and what it has
  # spent TODAY, whatever range was asked for.
  class UsageKey < Model
    # @return [String] the api key id — the same id a `group_by: "key"` series
    #   buckets under.
    def id = @raw["id"]

    # @return [String] the label the key was created with.
    def name = @raw["name"]

    # @return [String] `"secret"` or `"publishable"`.
    def kind = @raw["kind"]

    # @return [Boolean]
    def secret? = kind == "secret"

    # @return [Boolean]
    def publishable? = kind == "publishable"

    # @return [Integer, nil] the per-UTC-day credit ceiling; nil is unlimited.
    #   Only publishable keys are capped.
    def daily_credit_limit = @raw["dailyCreditLimit"]

    # @return [Boolean] whether this key has a daily ceiling at all.
    def capped? = !daily_credit_limit.nil?

    # @return [Integer] credits spent so far today (UTC).
    def used_today = @raw["usedToday"] || 0

    # @return [Integer, nil] what is left of {#daily_credit_limit} today, or
    #   nil for an uncapped key. Never negative.
    def remaining_today
      limit = daily_credit_limit
      limit.nil? ? nil : [limit - used_today, 0].max
    end
  end

  # The whole `GET /usage` body: the resolved window, the undivided totals, one
  # bucket per value of the grouped dimension, and the account's key gauge.
  class UsageReport < Model
    # @return [String] ISO-8601 instant the window starts at. Note this is an
    #   instant, not the `YYYY-MM-DD` the query takes — `from[0, 10]` for the day.
    def from = range["from"]

    # @return [String] ISO-8601 instant the window ends at (inclusive).
    def to = range["to"]

    # @return [String] the dimension `series` is bucketed along; one of
    #   {Usage::GROUP_BY}. Echoed by the api, so it is what was actually applied.
    def group_by = @raw["groupBy"]

    # @return [UsageTotals]
    def totals = @totals ||= UsageTotals.new(@raw["totals"] || {})

    # @return [Array<UsageSeriesEntry>] oldest-first for `group_by: "day"`
    #   (zero-filled across the whole range), busiest-first otherwise.
    def series = @series ||= Array(@raw["series"]).map { |row| UsageSeriesEntry.new(row) }

    # @return [Array<UsageKey>] every live api key on the account. EMPTY for an
    #   embed-token caller: a page-scoped credential may not enumerate the
    #   account's keys, so the api omits the gauge entirely.
    def keys = @keys ||= Array(@raw["keys"]).map { |row| UsageKey.new(row) }

    # One bucket by its dimension value.
    #
    # @param key [String] e.g. `"upscale"`, `"2026-09-13"`, an api key id.
    # @return [UsageSeriesEntry, nil]
    def bucket(key)
      series.find { |entry| entry.key == key }
    end

    private

    def range
      @raw["range"] || {}
    end
  end
end

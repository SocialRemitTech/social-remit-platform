-- ============================================================================
-- Social Remit — platform building blocks
-- Applied to EVERY service database/schema. Never contains domain tables.
--
-- Ownership: platform team. A service may not alter these tables; it may only
-- read/write them through SocialRemit.BuildingBlocks.Messaging and .Api.
--
-- Target: PostgreSQL 16 (Aurora). Idempotent — safe to re-run.
-- ============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- Transactional outbox
--
-- Written in the SAME transaction as the state change it describes. A relay
-- publishes committed rows to EventBridge. This is the only sanctioned way a
-- service emits a domain event (Baseline 2.0 §2.4.3).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS outbox_events (
    id                bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id          uuid        NOT NULL UNIQUE,
    event_type        text        NOT NULL,
    event_version     int         NOT NULL DEFAULT 1,
    subject_id        text        NOT NULL,
    correlation_id    uuid        NOT NULL,
    causation_id      uuid        NULL,
    traceparent       text        NULL,
    payload           jsonb       NOT NULL,
    occurred_at       timestamptz NOT NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),

    status            text        NOT NULL DEFAULT 'PENDING'
                                  CHECK (status IN ('PENDING','PUBLISHING','PUBLISHED','FAILED')),
    attempts          int         NOT NULL DEFAULT 0,
    next_attempt_at   timestamptz NOT NULL DEFAULT now(),
    published_at      timestamptz NULL,
    last_error        text        NULL,

    CONSTRAINT outbox_event_type_format CHECK (event_type ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$')
);

-- Relay claim index: the hot path is "oldest due, unpublished".
CREATE INDEX IF NOT EXISTS ix_outbox_due
    ON outbox_events (next_attempt_at, id)
    WHERE status IN ('PENDING','FAILED');

-- Ordering guarantee is per subject, not global. The relay claims batches
-- grouped by subject_id so two events about one customer never overtake.
CREATE INDEX IF NOT EXISTS ix_outbox_subject
    ON outbox_events (subject_id, id)
    WHERE status <> 'PUBLISHED';

-- Retention: published rows are pruned by a scheduled job, NOT on publish.
-- Keeping them briefly allows replay and duplicate-publication forensics.
CREATE INDEX IF NOT EXISTS ix_outbox_published_at
    ON outbox_events (published_at)
    WHERE status = 'PUBLISHED';


-- ---------------------------------------------------------------------------
-- Consumer inbox
--
-- Deduplication evidence for at-least-once delivery. A consumer records the
-- eventId in the SAME transaction as the effect it applied. Redelivery finds
-- the row and skips (Baseline 2.0 §2.4.4).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inbox_messages (
    event_id       uuid        NOT NULL,
    consumer       text        NOT NULL,   -- logical handler name, e.g. 'customer-journey.prospect-projector'
    event_type     text        NOT NULL,
    event_version  int         NOT NULL,
    correlation_id uuid        NOT NULL,
    received_at    timestamptz NOT NULL DEFAULT now(),
    processed_at   timestamptz NULL,
    status         text        NOT NULL DEFAULT 'PROCESSING'
                               CHECK (status IN ('PROCESSING','PROCESSED','SKIPPED','FAILED')),
    attempts       int         NOT NULL DEFAULT 1,
    last_error     text        NULL,
    PRIMARY KEY (event_id, consumer)
);

CREATE INDEX IF NOT EXISTS ix_inbox_unprocessed
    ON inbox_messages (received_at)
    WHERE status IN ('PROCESSING','FAILED');


-- ---------------------------------------------------------------------------
-- Idempotency records
--
-- Postgres, not Redis: these must survive cache eviction. Scope is
-- (key, route, subject) so a client reusing a key on a different endpoint is
-- rejected rather than silently replaying an unrelated response.
--
-- request_hash is a hash of the canonicalised body. Same key + different body
-- => IDEMPOTENCY_KEY_REUSED (409), never a silent overwrite.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS idempotency_records (
    idempotency_key   text        NOT NULL,
    route_key         text        NOT NULL,   -- 'POST /v1/phone-challenges'
    subject_key       text        NOT NULL,   -- customerId | journeyId | deviceInstallationIdHash | 'anonymous'
    request_hash      bytea       NOT NULL,

    status            text        NOT NULL DEFAULT 'IN_PROGRESS'
                                  CHECK (status IN ('IN_PROGRESS','COMPLETED','FAILED')),
    response_status   int         NULL,
    response_body     jsonb       NULL,
    response_headers  jsonb       NULL,

    correlation_id    uuid        NOT NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),
    completed_at      timestamptz NULL,
    expires_at        timestamptz NOT NULL,

    PRIMARY KEY (idempotency_key, route_key, subject_key)
);

CREATE INDEX IF NOT EXISTS ix_idempotency_expiry ON idempotency_records (expires_at);

-- Stale IN_PROGRESS rows (process died mid-request) are reclaimed by the
-- sweeper below rather than blocking the caller forever.
CREATE INDEX IF NOT EXISTS ix_idempotency_stuck
    ON idempotency_records (created_at)
    WHERE status = 'IN_PROGRESS';


-- ---------------------------------------------------------------------------
-- Housekeeping
--
-- Run from a scheduled task, not from request handlers. Retention values are
-- CONFIGURATION (Baseline 2.0 §33) — these defaults are prototype values and
-- must be confirmed against the retention schedule before go-live.
-- PLACEHOLDER: retention/deletion schedule owner = Engineering/Compliance.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION platform_prune(
    p_outbox_retention      interval DEFAULT interval '14 days',
    p_inbox_retention       interval DEFAULT interval '30 days',
    p_idempotency_stuck_ttl interval DEFAULT interval '10 minutes'
) RETURNS TABLE (outbox_pruned bigint, inbox_pruned bigint, idempotency_reclaimed bigint)
LANGUAGE plpgsql AS $$
DECLARE
    v_outbox bigint;
    v_inbox  bigint;
    v_idem   bigint;
BEGIN
    DELETE FROM outbox_events
     WHERE status = 'PUBLISHED' AND published_at < now() - p_outbox_retention;
    GET DIAGNOSTICS v_outbox = ROW_COUNT;

    DELETE FROM inbox_messages
     WHERE status IN ('PROCESSED','SKIPPED') AND processed_at < now() - p_inbox_retention;
    GET DIAGNOSTICS v_inbox = ROW_COUNT;

    -- A stuck IN_PROGRESS record is released, not completed. The retry then
    -- re-executes the handler, which is safe because handlers are idempotent
    -- at the domain level too.
    DELETE FROM idempotency_records
     WHERE status = 'IN_PROGRESS' AND created_at < now() - p_idempotency_stuck_ttl;
    GET DIAGNOSTICS v_idem = ROW_COUNT;

    DELETE FROM idempotency_records WHERE expires_at < now();

    RETURN QUERY SELECT v_outbox, v_inbox, v_idem;
END;
$$;

COMMIT;

-- ============================================================================
-- Operational notes
--
-- 1. The relay claims work with:
--        SELECT ... FROM outbox_events
--         WHERE status IN ('PENDING','FAILED') AND next_attempt_at <= now()
--         ORDER BY id
--         FOR UPDATE SKIP LOCKED
--         LIMIT :batch;
--    SKIP LOCKED lets several ECS tasks relay concurrently without contention
--    and without a leader election.
--
-- 2. A row that exceeds max attempts is left FAILED with last_error set and
--    raises an alarm. It is never dropped — the event is a committed fact and
--    losing it silently would break the PROSPECT invariant.
--
-- 3. Never publish from a request handler. If you find yourself needing the
--    event published before the response returns, the design is wrong: return
--    a SETUP_COMPLETING status and let the client poll.
-- ============================================================================

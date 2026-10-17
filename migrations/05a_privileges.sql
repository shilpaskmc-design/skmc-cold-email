-- ============================================================================
-- Migration 05a — Privileges & role baseline (outreach_db)
-- Implements: docs/database-schema.md §5.18 (Privileges, migration step 05a)
--
-- STATUS: APPLIED ON PRODUCTION (KRA VPS, container skmc-cold-email-postgres-1).
--   - Role creation + table grants: applied during initial Phase 2 schema setup.
--   - CONNECT on outreach_db + USAGE on schema public: were MISSING from the
--     original application and fixed manually on 2026-10-18 (outreach_app could
--     not CONNECT at all). Encoded here so fresh deploys reproduce the fixed state.
--
-- KNOWN GAP (not this file's scope): migrations 01-04, 05, 06 (databases,
--   extensions, enums, tables, indexes, seed config) were applied ad-hoc during
--   Phase 2 and have no file baseline yet. Tracked for Phase 2 follow-up.
--
-- Idempotent: safe to re-run.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Roles (least privilege; doc §3)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'outreach_app') THEN
    CREATE ROLE outreach_app LOGIN;  -- application runtime
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'outreach_admin') THEN
    CREATE ROLE outreach_admin LOGIN;  -- migrations/ops
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Database- and schema-level access
-- ---------------------------------------------------------------------------
GRANT CONNECT ON DATABASE outreach_db TO outreach_app;
GRANT USAGE ON SCHEMA public TO outreach_app;
GRANT USAGE ON SCHEMA public TO outreach_admin;

-- ---------------------------------------------------------------------------
-- Append-only history/audit tables: runtime role may only SELECT and INSERT.
-- UPDATE and DELETE are explicitly revoked so audit history cannot be
-- rewritten or erased by ordinary workflow operation (Architecture v1.3
-- §2 Principle #14, §31 Invariant #12).
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT ON verification_results, suppression_events,
     lifecycle_events, config_history TO outreach_app;
REVOKE UPDATE, DELETE ON verification_results, suppression_events,
     lifecycle_events, config_history FROM outreach_app;

-- suppression_list is current state: soft-deactivation is a legitimate
-- UPDATE; physical DELETE is prohibited at runtime.
GRANT SELECT, INSERT, UPDATE ON suppression_list TO outreach_app;
REVOKE DELETE ON suppression_list FROM outreach_app;

-- ---------------------------------------------------------------------------
-- Remaining operational tables: SELECT/INSERT/UPDATE as required by workflows;
-- no DELETE grants are issued to outreach_app (soft-deactivation pattern).
-- List verified against live production grants 2026-10-17 (17 tables total).
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE ON companies, leads, lead_enrichment,
     campaigns, campaign_assignments, email_events, replies,
     sending_domains, mailboxes, policy_config, workflow_runs,
     dead_letter_events TO outreach_app;

-- outreach_admin retains full ownership-level privileges for migrations.
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO outreach_admin;

COMMIT;

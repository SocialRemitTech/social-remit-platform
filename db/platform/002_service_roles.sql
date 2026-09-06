-- ============================================================================
-- Social Remit — per-service database roles
--
-- Run ONCE per environment, after the Aurora cluster exists and before the first
-- service deploys. Run as the RDS master user.
--
-- Why this is SQL and not Terraform: creating a role requires a connection to the
-- database, which lives in an isolated subnet with no internet route. A Terraform
-- runner would need a bastion or a VPC-attached runner just to manage roles.
-- Running it as a migration task inside the VPC is simpler and keeps the
-- credentials out of Terraform state.
--
--   psql "$MASTER_CONNECTION_STRING" -v ON_ERROR_STOP=1 -f 002_service_roles.sql
--
-- ── The rule this file enforces ────────────────────────────────────────────
--
-- A service can read and write ONLY its own schema. Not "should not" — cannot.
-- Cross-service SQL is the single fastest way to turn microservices back into a
-- distributed monolith: it looks like a shortcut, it works, and then two services
-- own the same table and neither can change it.
--
-- Enforcing that in the database rather than in code review means the shortcut is
-- not available even under deadline pressure.
-- ============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------------
-- Revoke the permissive defaults
--
-- PostgreSQL grants CREATE and USAGE on `public` to every role by default. On a
-- shared cluster that means any service could create tables anywhere.
-- ---------------------------------------------------------------------------
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON DATABASE socialremit FROM PUBLIC;


-- ---------------------------------------------------------------------------
-- Role and schema per service
--
-- Passwords are NOT set here. Each role's password is created by IAM database
-- authentication or set out of band from Secrets Manager:
--
--   ALTER ROLE svc_identity_access WITH PASSWORD '...';
--
-- Preferred: rds_iam, which issues short-lived tokens and removes stored
-- passwords entirely.
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    svc         text;
    schema_name text;
    role_name   text;
    services    text[] := ARRAY[
        'identity_access',
        'customer_journey',
        'consent_legal',
        'notification',
        'audit_reporting',
        'provider_integration',
        'mobile_bff'
    ];
BEGIN
    FOREACH svc IN ARRAY services LOOP
        schema_name := svc;
        role_name   := 'svc_' || svc;

        -- Owner role: used only by migration tasks. Can change the schema.
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name || '_owner') THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', role_name || '_owner');
        END IF;

        -- Application role: used by the running service. Can read and write data
        -- but CANNOT alter the schema. A service that cannot DROP TABLE cannot
        -- drop a table by accident at 3am.
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
            EXECUTE format('CREATE ROLE %I LOGIN', role_name);
        END IF;

        EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I AUTHORIZATION %I',
                       schema_name, role_name || '_owner');

        -- Only this service's roles may even see the schema.
        EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', schema_name);
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', schema_name, role_name);

        EXECUTE format(
            'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO %I',
            schema_name, role_name);
        EXECUTE format(
            'GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %I TO %I',
            schema_name, role_name);

        -- Default privileges apply to tables created LATER by the owner. Without
        -- this, every future migration needs a matching GRANT, and the one someone
        -- forgets fails in production rather than in CI.
        EXECUTE format(
            'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I
             GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I',
            role_name || '_owner', schema_name, role_name);
        EXECUTE format(
            'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I
             GRANT USAGE, SELECT ON SEQUENCES TO %I',
            role_name || '_owner', schema_name, role_name);

        -- The search_path pins the role to its own schema. A query that forgets to
        -- qualify a table name resolves inside the service's own schema or fails —
        -- it never silently reaches another service's data.
        EXECUTE format('ALTER ROLE %I SET search_path TO %I', role_name, schema_name);
        EXECUTE format('ALTER ROLE %I SET search_path TO %I', role_name || '_owner', schema_name);

        -- Short statement timeout for the application role. A runaway query holds
        -- connections and locks; failing it fast is better than letting it take the
        -- service down. Migrations need longer, so the owner gets its own limit.
        EXECUTE format('ALTER ROLE %I SET statement_timeout TO ''30s''', role_name);
        EXECUTE format('ALTER ROLE %I SET idle_in_transaction_session_timeout TO ''60s''', role_name);
        EXECUTE format('ALTER ROLE %I SET statement_timeout TO ''15min''', role_name || '_owner');

        -- IAM database authentication: no stored password at all.
        EXECUTE format('GRANT rds_iam TO %I', role_name);

        RAISE NOTICE 'Configured % (schema %)', role_name, schema_name;
    END LOOP;
END
$$;


-- ---------------------------------------------------------------------------
-- Verification
--
-- Prove the isolation actually holds rather than assuming it. Run this after the
-- block above; every row should show a service seeing only its own schema.
-- ---------------------------------------------------------------------------
COMMIT;

SELECT
    r.rolname                                   AS role,
    n.nspname                                   AS schema,
    has_schema_privilege(r.rolname, n.nspname, 'USAGE')  AS can_use,
    has_schema_privilege(r.rolname, n.nspname, 'CREATE') AS can_create
FROM pg_roles r
CROSS JOIN pg_namespace n
WHERE r.rolname LIKE 'svc\_%'
  AND r.rolname NOT LIKE '%\_owner'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  AND has_schema_privilege(r.rolname, n.nspname, 'USAGE')
ORDER BY 1, 2;

-- Expected: exactly one row per service role, naming its own schema, with
-- can_create = false. Any role appearing against a schema that is not its own is
-- a misconfiguration — stop and fix it before deploying anything.

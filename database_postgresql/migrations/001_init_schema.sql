-- Crowdfund Platform - PostgreSQL Initial Schema
-- This migration creates core entities: users, projects, pledges, transactions, and supporting tables.
-- It also defines constraints, indexes, and triggers for integrity and performance.
-- Run order: 001_init_schema.sql (idempotent-safe using IF NOT EXISTS where possible)

-- SCHEMA METADATA
CREATE TABLE IF NOT EXISTS schema_migrations (
    id SERIAL PRIMARY KEY,
    version VARCHAR(50) UNIQUE NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    description TEXT
);

INSERT INTO schema_migrations (version, description)
SELECT '001', 'Initial schema: users, projects, categories, rewards, pledges, transactions, sessions, refresh tokens'
WHERE NOT EXISTS (SELECT 1 FROM schema_migrations WHERE version = '001');

-- EXTENSIONS (safe create)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS citext;

-- ENUMS
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'project_status') THEN
        CREATE TYPE project_status AS ENUM ('draft', 'active', 'successful', 'failed', 'cancelled');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'transaction_status') THEN
        CREATE TYPE transaction_status AS ENUM ('pending', 'succeeded', 'failed', 'refunded', 'cancelled');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pledge_status') THEN
        CREATE TYPE pledge_status AS ENUM ('pending', 'collected', 'refunded', 'cancelled');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'currency_code') THEN
        CREATE TYPE currency_code AS ENUM ('USD', 'EUR', 'GBP');
    END IF;
END$$;

-- TABLE: users
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email CITEXT NOT NULL UNIQUE,
    username CITEXT UNIQUE,
    password_hash TEXT, -- nullable to allow social logins
    full_name TEXT,
    avatar_url TEXT,
    is_email_verified BOOLEAN NOT NULL DEFAULT FALSE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    role TEXT NOT NULL DEFAULT 'user', -- 'user', 'admin'
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_login_at TIMESTAMPTZ,
    CONSTRAINT chk_role CHECK (role IN ('user', 'admin'))
);

-- TABLE: categories (for projects)
CREATE TABLE IF NOT EXISTS categories (
    id SERIAL PRIMARY KEY,
    slug CITEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    description TEXT
);

-- TABLE: projects
CREATE TABLE IF NOT EXISTS projects (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    owner_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    category_id INT REFERENCES categories(id) ON DELETE SET NULL,
    title TEXT NOT NULL,
    slug CITEXT UNIQUE,
    description TEXT NOT NULL,
    short_description TEXT,
    media_url TEXT,
    goal_amount NUMERIC(12,2) NOT NULL CHECK (goal_amount > 0),
    currency currency_code NOT NULL DEFAULT 'USD',
    amount_raised NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (amount_raised >= 0),
    min_pledge NUMERIC(12,2) CHECK (min_pledge >= 0),
    deadline TIMESTAMPTZ,
    status project_status NOT NULL DEFAULT 'draft',
    location TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    published_at TIMESTAMPTZ,
    CONSTRAINT chk_deadline_future CHECK (deadline IS NULL OR deadline > created_at)
);

-- TABLE: rewards (optional tiers)
CREATE TABLE IF NOT EXISTS rewards (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    description TEXT,
    amount NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    quantity INT, -- optional cap
    claimed_count INT NOT NULL DEFAULT 0 CHECK (claimed_count >= 0),
    estimated_delivery DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(project_id, title)
);

-- TABLE: pledges
CREATE TABLE IF NOT EXISTS pledges (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    reward_id UUID REFERENCES rewards(id) ON DELETE SET NULL,
    amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    currency currency_code NOT NULL DEFAULT 'USD',
    status pledge_status NOT NULL DEFAULT 'pending',
    message TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    collected_at TIMESTAMPTZ,
    refunded_at TIMESTAMPTZ
);

-- TABLE: transactions (payment processor records per pledge)
CREATE TABLE IF NOT EXISTS transactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    pledge_id UUID NOT NULL REFERENCES pledges(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    provider TEXT NOT NULL, -- e.g., 'stripe'
    provider_payment_intent_id TEXT, -- unique per provider if available
    provider_charge_id TEXT,
    status transaction_status NOT NULL DEFAULT 'pending',
    amount NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    currency currency_code NOT NULL DEFAULT 'USD',
    fee_amount NUMERIC(12,2) DEFAULT 0 CHECK (fee_amount >= 0),
    net_amount NUMERIC(12,2) GENERATED ALWAYS AS (amount - COALESCE(fee_amount,0)) STORED,
    error_code TEXT,
    error_message TEXT,
    raw_response JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    succeeded_at TIMESTAMPTZ,
    failed_at TIMESTAMPTZ,
    refunded_at TIMESTAMPTZ
);

-- TABLE: user_sessions (for auth sessions)
CREATE TABLE IF NOT EXISTS user_sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    user_agent TEXT,
    ip_address INET,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

-- TABLE: refresh_tokens (for JWT refresh)
CREATE TABLE IF NOT EXISTS refresh_tokens (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    session_id UUID REFERENCES user_sessions(id) ON DELETE SET NULL,
    token_hash TEXT NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_refresh_valid CHECK (expires_at > created_at)
);

-- Additional supporting table: project_followers (users can follow projects)
CREATE TABLE IF NOT EXISTS project_followers (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, project_id)
);

-- INDEXES

-- users
CREATE INDEX IF NOT EXISTS idx_users_email ON users (email);
CREATE INDEX IF NOT EXISTS idx_users_username ON users (username);

-- projects
CREATE INDEX IF NOT EXISTS idx_projects_owner ON projects (owner_id);
CREATE INDEX IF NOT EXISTS idx_projects_status ON projects (status);
CREATE INDEX IF NOT EXISTS idx_projects_category ON projects (category_id);
CREATE INDEX IF NOT EXISTS idx_projects_slug ON projects (slug);
CREATE INDEX IF NOT EXISTS idx_projects_deadline ON projects (deadline);
CREATE INDEX IF NOT EXISTS idx_projects_created_at ON projects (created_at);

-- rewards
CREATE INDEX IF NOT EXISTS idx_rewards_project ON rewards (project_id);

-- pledges
CREATE INDEX IF NOT EXISTS idx_pledges_project ON pledges (project_id);
CREATE INDEX IF NOT EXISTS idx_pledges_user ON pledges (user_id);
CREATE INDEX IF NOT EXISTS idx_pledges_status ON pledges (status);
CREATE INDEX IF NOT EXISTS idx_pledges_created_at ON pledges (created_at);

-- transactions
CREATE INDEX IF NOT EXISTS idx_transactions_pledge ON transactions (pledge_id);
CREATE INDEX IF NOT EXISTS idx_transactions_user ON transactions (user_id);
CREATE INDEX IF NOT EXISTS idx_transactions_project ON transactions (project_id);
CREATE INDEX IF NOT EXISTS idx_transactions_status ON transactions (status);
CREATE INDEX IF NOT EXISTS idx_transactions_provider_intent ON transactions (provider, provider_payment_intent_id);

-- sessions and tokens
CREATE INDEX IF NOT EXISTS idx_user_sessions_user ON user_sessions (user_id);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user ON refresh_tokens (user_id);

-- CONSTRAINTS AND BUSINESS LOGIC

-- Ensure pledge currency matches project currency
ALTER TABLE pledges
    ADD CONSTRAINT IF NOT EXISTS fk_pledges_project_currency
    FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;

-- Trigger functions

-- 1) Normalize slug generation for projects when null
CREATE OR REPLACE FUNCTION gen_project_slug()
RETURNS TRIGGER AS $$
DECLARE
    base_slug TEXT;
    candidate TEXT;
    i INT := 1;
BEGIN
    IF NEW.slug IS NULL OR length(trim(NEW.slug)) = 0 THEN
        base_slug := regexp_replace(lower(NEW.title), '[^a-z0-9]+', '-', 'g');
        base_slug := trim(both '-' from base_slug);
        candidate := base_slug;
        WHILE EXISTS (SELECT 1 FROM projects p WHERE p.slug = candidate AND p.id <> NEW.id) LOOP
            i := i + 1;
            candidate := base_slug || '-' || i::TEXT;
        END LOOP;
        NEW.slug := candidate;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_projects_gen_slug ON projects;
CREATE TRIGGER trg_projects_gen_slug
BEFORE INSERT OR UPDATE ON projects
FOR EACH ROW
EXECUTE FUNCTION gen_project_slug();

-- 2) Update updated_at on changes
CREATE OR REPLACE FUNCTION touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Attach to tables
DROP TRIGGER IF EXISTS trg_users_touch ON users;
CREATE TRIGGER trg_users_touch BEFORE UPDATE ON users
FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

DROP TRIGGER IF EXISTS trg_projects_touch ON projects;
CREATE TRIGGER trg_projects_touch BEFORE UPDATE ON projects
FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

DROP TRIGGER IF EXISTS trg_pledges_touch ON pledges;
CREATE TRIGGER trg_pledges_touch BEFORE UPDATE ON pledges
FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

DROP TRIGGER IF EXISTS trg_transactions_touch ON transactions;
CREATE TRIGGER trg_transactions_touch BEFORE UPDATE ON transactions
FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- 3) Enforce reward quantity availability and increment claimed_count on pledge create
CREATE OR REPLACE FUNCTION enforce_reward_quantity()
RETURNS TRIGGER AS $$
DECLARE
    avail INT;
BEGIN
    IF NEW.reward_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT quantity, claimed_count INTO STRICT avail, NEW.amount
    FROM rewards r
    JOIN rewards r2 ON r2.id = NEW.reward_id
    WHERE r.id = NEW.reward_id;

    -- If reward has quantity cap, ensure not exceeded
    IF (SELECT quantity FROM rewards WHERE id = NEW.reward_id) IS NOT NULL THEN
        IF (SELECT claimed_count FROM rewards WHERE id = NEW.reward_id) >= (SELECT quantity FROM rewards WHERE id = NEW.reward_id) THEN
            RAISE EXCEPTION 'Reward is sold out';
        END IF;
    END IF;

    -- When reward has a price, ensure pledge meets or exceeds it
    IF (SELECT amount FROM rewards WHERE id = NEW.reward_id) IS NOT NULL THEN
        IF NEW.amount < (SELECT amount FROM rewards WHERE id = NEW.reward_id) THEN
            RAISE EXCEPTION 'Pledge amount (%) is less than reward minimum (%)', NEW.amount, (SELECT amount FROM rewards WHERE id = NEW.reward_id);
        END IF;
    END IF;

    -- Increment claimed_count
    UPDATE rewards
        SET claimed_count = claimed_count + 1
    WHERE id = NEW.reward_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_pledges_enforce_reward ON pledges;
CREATE TRIGGER trg_pledges_enforce_reward
BEFORE INSERT ON pledges
FOR EACH ROW
EXECUTE FUNCTION enforce_reward_quantity();

-- 4) When transaction succeeds, mark pledge as collected and increase project amount_raised
CREATE OR REPLACE FUNCTION apply_transaction_effects()
RETURNS TRIGGER AS $$
BEGIN
    -- Only apply on transitions to succeeded
    IF (TG_OP = 'INSERT' AND NEW.status = 'succeeded')
       OR (TG_OP = 'UPDATE' AND NEW.status = 'succeeded' AND OLD.status IS DISTINCT FROM 'succeeded') THEN

        -- Mark pledge as collected
        UPDATE pledges
           SET status = 'collected',
               collected_at = COALESCE(collected_at, NOW())
         WHERE id = NEW.pledge_id
           AND status IN ('pending');

        -- Increase project amount_raised by net_amount
        UPDATE projects
           SET amount_raised = amount_raised + NEW.net_amount
         WHERE id = NEW.project_id;
    END IF;

    -- If transaction refunded, set pledge refunded if appropriate and decrease amount_raised
    IF (TG_OP = 'UPDATE' AND NEW.status = 'refunded' AND OLD.status <> 'refunded') THEN
        UPDATE pledges
           SET status = 'refunded',
               refunded_at = COALESCE(refunded_at, NOW())
         WHERE id = NEW.pledge_id;

        UPDATE projects
           SET amount_raised = GREATEST(0, amount_raised - NEW.net_amount)
         WHERE id = NEW.project_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_transactions_effects_ins ON transactions;
CREATE TRIGGER trg_transactions_effects_ins
AFTER INSERT ON transactions
FOR EACH ROW EXECUTE FUNCTION apply_transaction_effects();

DROP TRIGGER IF EXISTS trg_transactions_effects_upd ON transactions;
CREATE TRIGGER trg_transactions_effects_upd
AFTER UPDATE ON transactions
FOR EACH ROW EXECUTE FUNCTION apply_transaction_effects();

-- 5) Ensure pledge/project/transaction currency consistency
CREATE OR REPLACE FUNCTION enforce_currency_consistency()
RETURNS TRIGGER AS $$
DECLARE
    proj_currency currency_code;
    pledge_currency currency_code;
BEGIN
    -- For pledges: match project currency
    IF TG_TABLE_NAME = 'pledges' THEN
        SELECT currency INTO proj_currency FROM projects WHERE id = NEW.project_id;
        IF NEW.currency <> proj_currency THEN
            RAISE EXCEPTION 'Pledge currency % must match project currency %', NEW.currency, proj_currency;
        END IF;
        RETURN NEW;
    END IF;

    -- For transactions: match pledge currency
    IF TG_TABLE_NAME = 'transactions' THEN
        SELECT currency INTO pledge_currency FROM pledges WHERE id = NEW.pledge_id;
        IF NEW.currency <> pledge_currency THEN
            RAISE EXCEPTION 'Transaction currency % must match pledge currency %', NEW.currency, pledge_currency;
        END IF;
        RETURN NEW;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_pledges_currency ON pledges;
CREATE TRIGGER trg_pledges_currency
BEFORE INSERT OR UPDATE ON pledges
FOR EACH ROW EXECUTE FUNCTION enforce_currency_consistency();

DROP TRIGGER IF EXISTS trg_transactions_currency ON transactions;
CREATE TRIGGER trg_transactions_currency
BEFORE INSERT OR UPDATE ON transactions
FOR EACH ROW EXECUTE FUNCTION enforce_currency_consistency();

-- 6) Ensure project status transitions based on goal and deadline
CREATE OR REPLACE FUNCTION evaluate_project_status()
RETURNS TRIGGER AS $$
BEGIN
    -- If amount_raised >= goal_amount and project is active, mark successful
    IF NEW.status = 'active' AND NEW.amount_raised >= NEW.goal_amount THEN
        NEW.status := 'successful';
        NEW.published_at := COALESCE(NEW.published_at, NOW());
    END IF;

    -- If deadline passed and not successful or cancelled, mark failed
    IF NEW.deadline IS NOT NULL AND NEW.deadline < NOW()
       AND NEW.status IN ('draft','active') THEN
        NEW.status := CASE WHEN NEW.amount_raised >= NEW.goal_amount THEN 'successful' ELSE 'failed' END;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_projects_evaluate ON projects;
CREATE TRIGGER trg_projects_evaluate
BEFORE INSERT OR UPDATE ON projects
FOR EACH ROW EXECUTE FUNCTION evaluate_project_status();

-- UNIQUE CONSTRAINTS WHERE APPLICABLE
ALTER TABLE transactions
    ADD CONSTRAINT IF NOT EXISTS uq_provider_intent UNIQUE (provider, provider_payment_intent_id);

-- SAMPLE SEED DATA (optional minimal, guarded)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM categories) THEN
        INSERT INTO categories (slug, name, description) VALUES
        ('technology', 'Technology', 'Tech innovations and gadgets'),
        ('art', 'Art', 'Creative art and installations'),
        ('games', 'Games', 'Board, video, and indie games'),
        ('music', 'Music', 'Albums, tours, and instruments');
    END IF;
END$$;

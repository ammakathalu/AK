-- ═══════════════════════════════════════════════════════════════
-- AMMAKATHA - SUPABASE SCHEMA
-- Designed for 1M+ users with partitioning, indexing & RLS
-- ═══════════════════════════════════════════════════════════════

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";        -- fuzzy text search
CREATE EXTENSION IF NOT EXISTS "pgcrypto";        -- PIN hashing
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements"; -- query monitoring

-- ───────────────────────────────────────────────
-- 1. LANGUAGES
-- ───────────────────────────────────────────────
CREATE TABLE languages (
  code        TEXT PRIMARY KEY,          -- 'te','ta','kn','hi','ml','mr'
  name_native TEXT NOT NULL,             -- 'తెలుగు'
  name_en     TEXT NOT NULL,             -- 'Telugu'
  font_family TEXT NOT NULL DEFAULT 'Noto Sans',
  is_active   BOOLEAN DEFAULT true,
  sort_order  INT DEFAULT 0
);

INSERT INTO languages VALUES
  ('te','తెలుగు','Telugu','Noto Serif Telugu',true,1),
  ('ta','தமிழ்','Tamil','Noto Serif Tamil',true,2),
  ('kn','ಕನ್ನಡ','Kannada','Noto Serif Kannada',true,3),
  ('hi','हिंदी','Hindi','Noto Serif Devanagari',true,4),
  ('ml','മലയാളം','Malayalam','Noto Serif Malayalam',true,5),
  ('mr','मराठी','Marathi','Noto Serif Devanagari',true,6);

-- ───────────────────────────────────────────────
-- 2. USERS  (partitioned by created_at month for scale)
-- ───────────────────────────────────────────────
CREATE TABLE users (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  phone           TEXT UNIQUE NOT NULL,           -- E.164 format: +919876543210
  pin_hash        TEXT NOT NULL,                  -- bcrypt hash of 6-digit PIN
  mother_name     TEXT,
  child_name      TEXT,
  child_age       SMALLINT CHECK (child_age BETWEEN 2 AND 12),
  lang_code       TEXT REFERENCES languages(code) DEFAULT 'te',
  voice_sample_url TEXT,                          -- ElevenLabs stored voice
  elevenlabs_voice_id TEXT,                       -- cloned voice ID
  subscription_status TEXT DEFAULT 'free'
    CHECK (subscription_status IN ('free','trial','active','expired','cancelled')),
  subscription_plan TEXT CHECK (subscription_plan IN ('monthly','annual','family')),
  subscription_start TIMESTAMPTZ,
  subscription_end   TIMESTAMPTZ,
  stories_played  INT DEFAULT 0,
  streak_days     SMALLINT DEFAULT 0,
  last_played_at  TIMESTAMPTZ,
  is_active       BOOLEAN DEFAULT true,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
) PARTITION BY RANGE (created_at);

-- Monthly partitions (add more as needed)
CREATE TABLE users_2025_01 PARTITION OF users FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
CREATE TABLE users_2025_06 PARTITION OF users FOR VALUES FROM ('2025-06-01') TO ('2025-07-01');
CREATE TABLE users_2025_07 PARTITION OF users FOR VALUES FROM ('2025-07-01') TO ('2025-08-01');
CREATE TABLE users_2025_08 PARTITION OF users FOR VALUES FROM ('2025-08-01') TO ('2025-09-01');
CREATE TABLE users_2025_09 PARTITION OF users FOR VALUES FROM ('2025-09-01') TO ('2025-10-01');
CREATE TABLE users_2025_10 PARTITION OF users FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');
CREATE TABLE users_2025_11 PARTITION OF users FOR VALUES FROM ('2025-11-01') TO ('2025-12-01');
CREATE TABLE users_2025_12 PARTITION OF users FOR VALUES FROM ('2025-12-01') TO ('2026-01-01');
CREATE TABLE users_2026_01 PARTITION OF users FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE users_2026_02 PARTITION OF users FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE users_2026_03 PARTITION OF users FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE users_2026_04 PARTITION OF users FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE users_2026_05 PARTITION OF users FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE users_default  PARTITION OF users DEFAULT;

-- Indexes for fast lookup at scale
CREATE INDEX idx_users_phone       ON users (phone);
CREATE INDEX idx_users_sub_status  ON users (subscription_status, subscription_end);
CREATE INDEX idx_users_lang        ON users (lang_code);
CREATE INDEX idx_users_created     ON users (created_at DESC);

-- Auto-update updated_at
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_users_updated BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ───────────────────────────────────────────────
-- 3. OTP / LOGIN SESSIONS
-- ───────────────────────────────────────────────
CREATE TABLE login_sessions (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id     UUID REFERENCES users(id) ON DELETE CASCADE,
  token_hash  TEXT NOT NULL,                      -- hashed session token
  device_info JSONB,                              -- browser/device metadata
  ip_address  INET,
  expires_at  TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '30 days'),
  created_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_sessions_user    ON login_sessions (user_id);
CREATE INDEX idx_sessions_expires ON login_sessions (expires_at);

-- Clean expired sessions automatically
CREATE OR REPLACE FUNCTION clean_expired_sessions() RETURNS void AS $$
  DELETE FROM login_sessions WHERE expires_at < NOW();
$$ LANGUAGE sql;

-- ───────────────────────────────────────────────
-- 4. STORIES
-- ───────────────────────────────────────────────
CREATE TABLE stories (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  lang_code       TEXT REFERENCES languages(code) NOT NULL,
  title           TEXT NOT NULL,
  slug            TEXT NOT NULL,
  category        TEXT NOT NULL CHECK (category IN ('panchatantra','tenali','folk','moral','festival','lullaby','custom')),
  age_min         SMALLINT DEFAULT 3,
  age_max         SMALLINT DEFAULT 10,
  duration_secs   INT,                            -- audio length in seconds
  emoji           TEXT DEFAULT '📖',
  thumbnail_url   TEXT,
  audio_url       TEXT,                           -- default narrator audio
  story_text      TEXT NOT NULL,
  moral_text      TEXT,
  tags            TEXT[] DEFAULT '{}',
  is_premium      BOOLEAN DEFAULT false,
  is_published    BOOLEAN DEFAULT false,
  play_count      BIGINT DEFAULT 0,
  rating_avg      NUMERIC(3,2) DEFAULT 0,
  rating_count    INT DEFAULT 0,
  created_by      UUID,                           -- admin who created
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_stories_slug_lang ON stories (slug, lang_code);
CREATE INDEX idx_stories_lang_cat  ON stories (lang_code, category, is_published);
CREATE INDEX idx_stories_premium   ON stories (is_premium, is_published);
CREATE INDEX idx_stories_age       ON stories (age_min, age_max);
CREATE INDEX idx_stories_tags      ON stories USING GIN (tags);
CREATE INDEX idx_stories_text      ON stories USING GIN (to_tsvector('simple', title || ' ' || story_text));

CREATE TRIGGER trg_stories_updated BEFORE UPDATE ON stories
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ───────────────────────────────────────────────
-- 5. USER GENERATED STORIES (AI)
-- ───────────────────────────────────────────────
CREATE TABLE user_stories (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id         UUID REFERENCES users(id) ON DELETE CASCADE,
  lang_code       TEXT REFERENCES languages(code),
  title           TEXT,
  story_text      TEXT NOT NULL,
  moral_text      TEXT,
  category        TEXT,
  setting         TEXT,
  moral_value     TEXT,
  ai_model        TEXT DEFAULT 'claude-sonnet-4-20250514',
  audio_url       TEXT,                           -- generated audio URL
  is_favourite    BOOLEAN DEFAULT false,
  created_at      TIMESTAMPTZ DEFAULT NOW()
) PARTITION BY RANGE (created_at);

CREATE TABLE user_stories_2025 PARTITION OF user_stories
  FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
CREATE TABLE user_stories_2026 PARTITION OF user_stories
  FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE user_stories_default PARTITION OF user_stories DEFAULT;

CREATE INDEX idx_user_stories_user ON user_stories (user_id, created_at DESC);

-- ───────────────────────────────────────────────
-- 6. PLAY HISTORY (high write volume - partitioned)
-- ───────────────────────────────────────────────
CREATE TABLE play_history (
  id          UUID DEFAULT uuid_generate_v4(),
  user_id     UUID NOT NULL,
  story_id    UUID,                               -- NULL for user_stories
  user_story_id UUID,
  lang_code   TEXT,
  played_secs INT DEFAULT 0,
  completed   BOOLEAN DEFAULT false,
  played_at   TIMESTAMPTZ DEFAULT NOW()
) PARTITION BY RANGE (played_at);

CREATE TABLE play_history_2025_q1 PARTITION OF play_history
  FOR VALUES FROM ('2025-01-01') TO ('2025-04-01');
CREATE TABLE play_history_2025_q2 PARTITION OF play_history
  FOR VALUES FROM ('2025-04-01') TO ('2025-07-01');
CREATE TABLE play_history_2025_q3 PARTITION OF play_history
  FOR VALUES FROM ('2025-07-01') TO ('2025-10-01');
CREATE TABLE play_history_2025_q4 PARTITION OF play_history
  FOR VALUES FROM ('2025-10-01') TO ('2026-01-01');
CREATE TABLE play_history_2026_q1 PARTITION OF play_history
  FOR VALUES FROM ('2026-01-01') TO ('2026-04-01');
CREATE TABLE play_history_2026_q2 PARTITION OF play_history
  FOR VALUES FROM ('2026-04-01') TO ('2026-07-01');
CREATE TABLE play_history_default  PARTITION OF play_history DEFAULT;

CREATE INDEX idx_play_user_date ON play_history (user_id, played_at DESC);

-- Materialised view for streak calculation (refresh nightly)
CREATE MATERIALIZED VIEW user_streaks AS
SELECT
  user_id,
  COUNT(DISTINCT DATE(played_at)) AS total_days,
  MAX(DATE(played_at)) AS last_day,
  (SELECT COUNT(*) FROM (
    SELECT DATE(played_at) d FROM play_history ph2
    WHERE ph2.user_id = ph.user_id
      AND played_at > NOW() - INTERVAL '60 days'
    GROUP BY d
    ORDER BY d DESC
  ) x) AS recent_days
FROM play_history ph
GROUP BY user_id;

CREATE UNIQUE INDEX ON user_streaks (user_id);

-- ───────────────────────────────────────────────
-- 7. SUBSCRIPTIONS & PAYMENTS
-- ───────────────────────────────────────────────
CREATE TABLE subscription_plans (
  id          TEXT PRIMARY KEY,                   -- 'monthly','annual','family'
  name_en     TEXT NOT NULL,
  price_inr   INT NOT NULL,
  duration_days INT NOT NULL,
  max_children SMALLINT DEFAULT 1,
  features    JSONB DEFAULT '{}',
  is_active   BOOLEAN DEFAULT true
);

INSERT INTO subscription_plans VALUES
  ('monthly',  'Monthly Plan',  99,  30,  1, '{"ai_stories":10,"download":true}', true),
  ('annual',   'Annual Plan',   799, 365, 1, '{"ai_stories":100,"download":true,"priority":true}', true),
  ('family',   'Family Plan',   149, 30,  5, '{"ai_stories":20,"download":true,"family":true}', true);

CREATE TABLE payments (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id         UUID REFERENCES users(id) ON DELETE SET NULL,
  plan_id         TEXT REFERENCES subscription_plans(id),
  amount_inr      INT NOT NULL,
  status          TEXT DEFAULT 'pending'
    CHECK (status IN ('pending','screenshot_uploaded','verified','rejected','refunded')),
  qr_code_id      UUID,                           -- which QR was shown
  screenshot_url  TEXT,                           -- user uploads payment proof
  verified_by     UUID,                           -- admin UUID
  verified_at     TIMESTAMPTZ,
  rejection_note  TEXT,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
) PARTITION BY RANGE (created_at);

CREATE TABLE payments_2025 PARTITION OF payments FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
CREATE TABLE payments_2026 PARTITION OF payments FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE payments_default PARTITION OF payments DEFAULT;

CREATE INDEX idx_payments_user    ON payments (user_id, created_at DESC);
CREATE INDEX idx_payments_status  ON payments (status);

CREATE TRIGGER trg_payments_updated BEFORE UPDATE ON payments
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ───────────────────────────────────────────────
-- 8. QR CODES (Admin managed)
-- ───────────────────────────────────────────────
CREATE TABLE payment_qr_codes (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  label       TEXT NOT NULL,                      -- 'PhonePe Main', 'GPay Backup'
  upi_id      TEXT,                               -- for display only
  qr_image_url TEXT NOT NULL,                     -- Supabase Storage URL
  is_active   BOOLEAN DEFAULT true,
  created_by  UUID,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ───────────────────────────────────────────────
-- 9. ADMINS
-- ───────────────────────────────────────────────
CREATE TABLE admins (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  email       TEXT UNIQUE NOT NULL,
  name        TEXT,
  role        TEXT DEFAULT 'admin' CHECK (role IN ('super','admin','support')),
  is_active   BOOLEAN DEFAULT true,
  last_login  TIMESTAMPTZ,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ───────────────────────────────────────────────
-- 10. APP CONFIG (key-value for runtime config)
-- ───────────────────────────────────────────────
CREATE TABLE app_config (
  key         TEXT PRIMARY KEY,
  value       TEXT,
  description TEXT,
  updated_at  TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO app_config VALUES
  ('free_stories_per_day',  '3',   'Stories free users can play per day', NOW()),
  ('free_ai_stories',       '1',   'AI stories free users can generate per month', NOW()),
  ('trial_days',            '7',   'Trial period in days after signup', NOW()),
  ('elevenlabs_api_key',    '',    'ElevenLabs API key', NOW()),
  ('claude_api_key',        '',    'Anthropic Claude API key', NOW()),
  ('support_whatsapp',      '',    'Support WhatsApp number', NOW()),
  ('app_name',              'AmmaKatha', 'App display name', NOW()),
  ('maintenance_mode',      'false','Put app in maintenance', NOW());

-- ───────────────────────────────────────────────
-- 11. VOICE SAMPLES (for ElevenLabs cloning)
-- ───────────────────────────────────────────────
CREATE TABLE voice_samples (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id         UUID REFERENCES users(id) ON DELETE CASCADE,
  storage_path    TEXT NOT NULL,                  -- Supabase storage path
  duration_secs   SMALLINT,
  elevenlabs_voice_id TEXT,                       -- returned after cloning
  clone_status    TEXT DEFAULT 'pending'
    CHECK (clone_status IN ('pending','processing','ready','failed')),
  created_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_voice_user ON voice_samples (user_id);

-- ───────────────────────────────────────────────
-- 12. PUSH NOTIFICATIONS LOG
-- ───────────────────────────────────────────────
CREATE TABLE notification_log (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id     UUID REFERENCES users(id) ON DELETE CASCADE,
  type        TEXT,                               -- 'bedtime_reminder','payment_verified' etc
  title       TEXT,
  body        TEXT,
  sent_at     TIMESTAMPTZ DEFAULT NOW(),
  opened_at   TIMESTAMPTZ
) PARTITION BY RANGE (sent_at);

CREATE TABLE notif_2025 PARTITION OF notification_log FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
CREATE TABLE notif_2026 PARTITION OF notification_log FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE notif_default PARTITION OF notification_log DEFAULT;

-- ───────────────────────────────────────────────
-- 13. ROW LEVEL SECURITY (RLS)
-- ───────────────────────────────────────────────
ALTER TABLE users           ENABLE ROW LEVEL SECURITY;
ALTER TABLE login_sessions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_stories    ENABLE ROW LEVEL SECURITY;
ALTER TABLE play_history    ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments        ENABLE ROW LEVEL SECURITY;
ALTER TABLE voice_samples   ENABLE ROW LEVEL SECURITY;

-- Users can only see their own data
CREATE POLICY users_self ON users
  FOR ALL USING (id = auth.uid()::UUID);

CREATE POLICY sessions_self ON login_sessions
  FOR ALL USING (user_id = auth.uid()::UUID);

CREATE POLICY user_stories_self ON user_stories
  FOR ALL USING (user_id = auth.uid()::UUID);

CREATE POLICY play_history_self ON play_history
  FOR ALL USING (user_id = auth.uid()::UUID);

CREATE POLICY payments_self ON payments
  FOR SELECT USING (user_id = auth.uid()::UUID);

CREATE POLICY voice_self ON voice_samples
  FOR ALL USING (user_id = auth.uid()::UUID);

-- Stories are public read (published only)
ALTER TABLE stories ENABLE ROW LEVEL SECURITY;
CREATE POLICY stories_public ON stories
  FOR SELECT USING (is_published = true);

-- ───────────────────────────────────────────────
-- 14. ANALYTICS VIEWS (for admin dashboard)
-- ───────────────────────────────────────────────
CREATE VIEW admin_stats AS
SELECT
  (SELECT COUNT(*) FROM users WHERE is_active = true)               AS total_users,
  (SELECT COUNT(*) FROM users WHERE subscription_status = 'active') AS paying_users,
  (SELECT COUNT(*) FROM users WHERE created_at > NOW() - INTERVAL '7 days') AS new_users_week,
  (SELECT COUNT(*) FROM payments WHERE status = 'screenshot_uploaded') AS pending_payments,
  (SELECT COALESCE(SUM(amount_inr),0) FROM payments WHERE status = 'verified'
   AND created_at > date_trunc('month', NOW()))                     AS revenue_this_month,
  (SELECT COUNT(*) FROM play_history WHERE played_at > NOW() - INTERVAL '24 hours') AS plays_today;

CREATE VIEW lang_stats AS
SELECT
  l.name_native, l.name_en, l.code,
  COUNT(u.id) AS user_count,
  COUNT(CASE WHEN u.subscription_status='active' THEN 1 END) AS paying_count
FROM languages l
LEFT JOIN users u ON u.lang_code = l.code
GROUP BY l.code, l.name_native, l.name_en
ORDER BY user_count DESC;

-- ───────────────────────────────────────────────
-- 15. STORAGE BUCKETS (run in Supabase dashboard)
-- ───────────────────────────────────────────────
-- Run these in Supabase Storage dashboard or via API:
--
-- bucket: 'voice-samples'     (private, per-user access)
-- bucket: 'story-audio'       (public CDN)
-- bucket: 'story-thumbnails'  (public CDN)
-- bucket: 'payment-qr'        (public read, admin write)
-- bucket: 'payment-screenshots' (private, user+admin access)
-- bucket: 'generated-audio'   (private, per-user access)

-- ───────────────────────────────────────────────
-- 16. PERFORMANCE: Connection pooling note
-- ───────────────────────────────────────────────
-- For 1M users, use Supabase's built-in PgBouncer (Transaction mode)
-- Set pool_size = 25 per instance
-- Use READ REPLICAS for analytics queries
-- Enable point-in-time recovery (PITR) for backups
-- Set up pg_cron for nightly materialized view refresh:
--   SELECT cron.schedule('refresh-streaks', '0 2 * * *',
--     'REFRESH MATERIALIZED VIEW CONCURRENTLY user_streaks');

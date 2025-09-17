CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text UNIQUE NOT NULL,
  name text NOT NULL,
  role text NOT NULL CHECK (role IN ('admin','staff','client')),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE clients (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid UNIQUE REFERENCES users(id) ON DELETE SET NULL,
  org_name text,
  abn text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE cases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reference text UNIQUE NOT NULL,
  client_id uuid NOT NULL REFERENCES clients(id) ON DELETE RESTRICT,
  manager_id uuid REFERENCES users(id) ON DELETE SET NULL,
  status text NOT NULL CHECK (status IN ('open','on_hold','closed')) DEFAULT 'open',
  stage text NOT NULL,
  opened_at timestamptz NOT NULL DEFAULT now(),
  closed_at timestamptz
);
CREATE TABLE tasks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id uuid NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  assignee_id uuid REFERENCES users(id) ON DELETE SET NULL,
  title text NOT NULL,
  status text NOT NULL CHECK (status IN ('todo','in_progress','waiting','done')) DEFAULT 'todo',
  due_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id uuid NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  uploader_id uuid REFERENCES users(id) ON DELETE SET NULL,
  kind text NOT NULL,
  storage_key text,
  filename text NOT NULL,
  mime text,
  size_bytes bigint,
  sha256_hex text,
  uploaded_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id uuid NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  author_id uuid REFERENCES users(id) ON DELETE SET NULL,
  body text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type text NOT NULL,
  payload_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE activity_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id uuid REFERENCES cases(id) ON DELETE CASCADE,
  actor_id uuid REFERENCES users(id) ON DELETE SET NULL,
  action text NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid,
  snapshot_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE creditors (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  contact_email text,
  contact_phone text
);
CREATE TABLE claims (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id uuid NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  creditor_id uuid NOT NULL REFERENCES creditors(id) ON DELETE RESTRICT,
  amount_claimed numeric(14,2) NOT NULL CHECK (amount_claimed >= 0),
  amount_admitted numeric(14,2) CHECK (amount_admitted >= 0),
  status text NOT NULL CHECK (status IN ('lodged','under_review','admitted','rejected')) DEFAULT 'lodged',
  lodged_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (case_id, creditor_id)
);
CREATE TABLE transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id uuid NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('receipt','payment','fee','interest')),
  amount numeric(14,2) NOT NULL CHECK (amount >= 0),
  currency char(3) NOT NULL DEFAULT 'AUD',
  occurred_at timestamptz NOT NULL,
  ref text,
  notes text
);
CREATE TABLE distributions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id uuid NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  round_no int NOT NULL,
  total_amount numeric(14,2) NOT NULL CHECK (total_amount >= 0),
  declared_at timestamptz NOT NULL DEFAULT now(),
  window_start date,
  window_end date,
  UNIQUE(case_id, round_no)
);
CREATE TABLE distribution_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  distribution_id uuid NOT NULL REFERENCES distributions(id) ON DELETE CASCADE,
  creditor_id uuid NOT NULL REFERENCES creditors(id) ON DELETE RESTRICT,
  amount numeric(14,2) NOT NULL CHECK (amount >= 0),
  UNIQUE(distribution_id, creditor_id)
);

CREATE INDEX IF NOT EXISTS idx_cases_client          ON cases(client_id);
CREATE INDEX IF NOT EXISTS idx_cases_manager         ON cases(manager_id);
CREATE INDEX IF NOT EXISTS idx_cases_status_stage    ON cases(status, stage);
CREATE INDEX IF NOT EXISTS idx_tasks_case_status     ON tasks(case_id, status);
CREATE INDEX IF NOT EXISTS idx_tasks_assignee        ON tasks(assignee_id);
CREATE INDEX IF NOT EXISTS idx_tasks_case_due        ON tasks(case_id, due_at);

CREATE INDEX IF NOT EXISTS idx_documents_case        ON documents(case_id);
CREATE INDEX IF NOT EXISTS idx_comments_case         ON comments(case_id);
CREATE INDEX IF NOT EXISTS idx_notifications_user    ON notifications(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_case_time    ON activity_log(case_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_claims_case           ON claims(case_id);
CREATE INDEX IF NOT EXISTS idx_claims_creditor       ON claims(creditor_id);
CREATE INDEX IF NOT EXISTS idx_tx_case_time          ON transactions(case_id, occurred_at);
CREATE INDEX IF NOT EXISTS idx_tx_case_kind_time     ON transactions(case_id, kind, occurred_at);
CREATE INDEX IF NOT EXISTS idx_dist_lines_dist       ON distribution_lines(distribution_id);

CREATE OR REPLACE VIEW case_status_counts_v AS
SELECT
  c.id AS case_id,
  SUM(CASE WHEN t.status IN ('todo','in_progress','waiting') THEN 1 ELSE 0 END) AS active_tasks,
  SUM(CASE WHEN t.due_at IS NOT NULL AND t.due_at < now() AND t.status <> 'done' THEN 1 ELSE 0 END) AS overdue_tasks,
  SUM(CASE WHEN t.due_at IS NOT NULL AND t.due_at >= now() AND t.due_at < now() + interval '7 days' AND t.status <> 'done' THEN 1 ELSE 0 END) AS upcoming_tasks_7d
FROM cases c
LEFT JOIN tasks t ON t.case_id = c.id
GROUP BY c.id;

CREATE OR REPLACE VIEW case_funds_summary_v AS
SELECT
  c.id AS case_id,
  COALESCE(SUM(CASE WHEN tx.kind IN ('receipt','interest') THEN tx.amount ELSE 0 END),0) AS total_in,
  COALESCE(SUM(CASE WHEN tx.kind IN ('payment','fee') THEN tx.amount ELSE 0 END),0) AS total_out,
  (COALESCE(SUM(CASE WHEN tx.kind IN ('receipt','interest') THEN tx.amount ELSE 0 END),0)
   - COALESCE(SUM(CASE WHEN tx.kind IN ('payment','fee') THEN tx.amount ELSE 0 END),0)) AS available_funds
FROM cases c
LEFT JOIN transactions tx ON tx.case_id = c.id
GROUP BY c.id;

CREATE OR REPLACE VIEW claims_verification_v AS
SELECT
  c.id AS case_id,
  COUNT(*) FILTER (WHERE cl.status IN ('lodged','under_review','admitted')) AS total_considered,
  COUNT(*) FILTER (WHERE cl.status = 'admitted') AS admitted_count,
  CASE
    WHEN COUNT(*) FILTER (WHERE cl.status IN ('lodged','under_review','admitted')) = 0 THEN 0
    ELSE ROUND(
      100.0 * COUNT(*) FILTER (WHERE cl.status = 'admitted')::numeric
      / NULLIF(COUNT(*) FILTER (WHERE cl.status IN ('lodged','under_review','admitted')), 0),
      2
    )
  END AS admitted_pct
FROM cases c
LEFT JOIN claims cl ON cl.case_id = c.id
GROUP BY c.id;

CREATE OR REPLACE VIEW distribution_progress_v AS
SELECT
  c.id AS case_id,
  COALESCE(SUM(dl.amount),0) AS distributed_total
FROM cases c
LEFT JOIN distributions d ON d.case_id = c.id
LEFT JOIN distribution_lines dl ON dl.distribution_id = d.id
GROUP BY c.id;

GRANT USAGE ON SCHEMA public TO olive_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO olive_app;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO olive_app;
GRANT SELECT ON ALL VIEWS IN SCHEMA public TO olive_app;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO olive_app;


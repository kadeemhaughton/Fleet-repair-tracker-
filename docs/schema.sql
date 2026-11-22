-- ============================================================================
-- Eventure Fleet Repair Tracker, Consolidated Database Schema
-- ============================================================================
--
-- WHAT THIS FILE IS
--   A single, consolidated, CURRENT-STATE view of the backend table-creation
--   specs for the "Eventure Fleet Repair Tracker". It is compiled from the 28
--   Supabase migration files in supabase/migrations/ (the authoritative source,
--   listed in the appendix at the bottom) and cross-checked against the
--   generated types in lib/database.types.ts, which reflect the FINAL schema.
--
--   For every table this shows ONE CREATE TABLE that merges the base definition
--   with every later `ALTER TABLE ... ADD COLUMN` / rename / drop / type change,
--   so each table lists ALL columns exactly as they exist now. It is a reference
--   document, not the migration history, to reproduce the DB incrementally, run
--   the numbered migrations in order instead.
--
-- DATABASE
--   Supabase Postgres 15. Primary keys are UUIDs (gen_random_uuid()). Money is
--   numeric(10,2); timestamps are timestamptz; dates are date.
--
-- SECURITY
--   Row-Level Security (RLS) is ENABLED on every table in the public schema.
--   Access is role-aware (see the RLS section near the bottom): internal "staff"
--   get full access; "body_shop" portal users are scoped to only their own
--   shop's cases/vehicles via SECURITY DEFINER helper functions, a safe view,
--   and a column-whitelisted write RPC. The Gmail-routing tables are staff-read
--   only; all their writes go through the service-role client.
--
--   Column-level notes:
--     - Inline `-- FK -> table(col)` comments mark foreign-key relationships.
--     - repair_cases.vehicle_plate (base) was renamed to vehicle_number, then
--       dropped once VIN became the vehicle identifier, it is GONE from the
--       final schema. repair_cases.fleet_id was renamed to vehicle_name.
-- ============================================================================


-- ============================================================================
-- SECTION 1, ENUM / USER-DEFINED TYPES
-- ============================================================================

-- Single source of truth for "where is this car right now".
-- ('total_loss' was appended later via migration 0011.)
create type repair_status as enum (
  'logged',
  'owner_notified',
  'routing',
  'no_claim_direct_repair',
  'claim_filed_awaiting_adjuster',
  'claim_denied_action_needed',
  'claim_approved_awaiting_appraisal',
  'reconciling_estimates',
  'cleared_for_repair',
  'in_repair',
  'complete_awaiting_payment',
  'closed',
  'total_loss'
);

-- Insurance claim outcome.
create type claim_result as enum (
  'pending',
  'approved',
  'denied'
);

-- NTTA toll leakage classification (migration 0015). Derived automatically from
-- whether a booking was open, see the generated `category` column on ntta_logs.
create type ntta_category as enum (
  'absorbed_expense',
  'chargeback'
);

-- Note: several other low-cardinality fields are modeled as text + CHECK
-- constraints rather than enum types, e.g.:
--   case_estimates.source            IN ('body_shop','appraiser')
--   case_payments.direction          IN ('inbound','outbound')
--   case_updates.party               IN ('adjuster','appraiser','body_shop','owner','other')
--   case_updates.direction           IN ('inbound','outbound')
--   case_updates.channel             IN ('call','email','voicemail','text','portal','in_person','other')
--   case_updates.source              IN ('manual','gmail')
--   case_notes.author_role           IN ('staff','body_shop')
--   profiles.role                    IN ('staff','body_shop')
--   gmail_connections.sweep_cadence  IN ('off','daily','weekly')
--   inbound_emails.action            IN ('route','queue','skip')
--   inbound_emails.matched_party     IN ('adjuster','appraiser','body_shop','owner','other')
--   inbound_emails.confidence_tier   IN ('HIGH','MEDIUM','LOW','NONE')
--   inbound_emails.status            IN ('matched','unrouted','ignored','error')


-- ============================================================================
-- SECTION 2, TABLES (consolidated current state)
-- ============================================================================
-- Order below resolves foreign keys where possible. The one genuinely circular
-- relationship (case_updates <-> inbound_emails) is closed with a trailing
-- ALTER TABLE at the end of this section.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- body_shops  (migration 0018)
--   Body shops as first-class entities: the scoping key for the portal.
-- ----------------------------------------------------------------------------
create table body_shops (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  contact_email text,
  contact_phone text,
  active        boolean not null default true,
  created_at    timestamptz default now()
);


-- ----------------------------------------------------------------------------
-- profiles  (migration 0018)
--   App user profiles: role + which shop (for body_shop users). One row per
--   auth user; a trigger (handle_new_user) seeds a 'staff' profile on signup.
-- ----------------------------------------------------------------------------
create table profiles (
  id            uuid primary key,                 -- FK -> auth.users(id) ON DELETE CASCADE
  role          text not null default 'staff'
                  check (role in ('staff', 'body_shop')),
  body_shop_id  uuid,                             -- FK -> body_shops(id)
  full_name     text,
  created_at    timestamptz default now(),
  -- A body_shop user must be linked to a shop; a staff user must not be.
  constraint profiles_shop_link check (
    (role = 'body_shop' and body_shop_id is not null) or
    (role = 'staff'     and body_shop_id is null)
  ),
  constraint profiles_id_fkey
    foreign key (id) references auth.users(id) on delete cascade,
  constraint profiles_body_shop_id_fkey
    foreign key (body_shop_id) references body_shops(id)
);


-- ----------------------------------------------------------------------------
-- repair_cases  (base 0001; + vin 0007; - vehicle_number 0008;
--   vehicle_plate->vehicle_number & fleet_id->vehicle_name 0005;
--   follow_up_manual 0010; settlement fields 0012; total_loss_estimate 0013;
--   follow_up_done 0014; body_shop_id 0018)
--   The central record: one row per vehicle-in-for-repair, carried end to end.
-- ----------------------------------------------------------------------------
create table repair_cases (
  id                    uuid primary key default gen_random_uuid(),
  created_at            timestamptz default now(),
  updated_at            timestamptz default now(),   -- kept fresh by set_updated_at trigger

  -- Vehicle identity
  vin                   text,                         -- added 0007; now the primary vehicle id
  vehicle_name          text,                         -- was base column fleet_id, renamed 0005
  -- (base column vehicle_plate -> renamed vehicle_number 0005 -> DROPPED 0008)

  -- Stage 1: Log and Notify
  owner_name            text not null,
  owner_contact         text,
  date_in               date not null default current_date,
  incident_description  text,
  current_location      text,
  owner_notified        boolean default false,

  -- Workflow control
  status                repair_status not null default 'logged',
  coordinator           text,                         -- the one person who owns this case end to end
  next_follow_up        date,                         -- +2 business days on every update to an open case
  follow_up_manual      boolean not null default false,  -- added 0010; when true, date is user-set (not auto-bumped)
  follow_up_done        boolean not null default false,  -- added 0014; per-case follow-up task checkoff

  -- Stage 2: Route (deductible test; deductible = 3500)
  claim_filed           boolean default false,
  body_shop_name        text,                         -- legacy free-text name (kept alongside body_shop_id)
  body_shop_id          uuid,                         -- added 0018; FK -> body_shops(id)
  estimated_damage      numeric(10,2),

  -- Stage 3: Claim Setup
  claim_number          text,
  adjuster_name         text,
  adjuster_contact      text,
  claim_result          claim_result default 'pending',
  denial_reason         text,
  denial_next_step      text,

  -- Stage 4: Estimate and Reconcile
  appraiser_name        text,
  appraiser_contact     text,
  appraiser_estimate    numeric(10,2),
  body_shop_estimate    numeric(10,2),
  supplement_needed     boolean default false,
  supplement_status     text,                         -- 'not_needed' | 'submitted' | 'approved'

  -- Stage 5: Repair
  repair_start          date,
  eta                   date,
  repair_complete       date,

  -- Total loss / settlement (added 0012 + 0013)
  total_loss_date       date,
  total_loss_estimate   numeric(10,2),                -- added 0013; separate from appraiser_estimate
  settlement_amount     numeric(10,2),
  settlement_options    text,
  settlement_next_steps text,

  -- Stage 6: Close
  payment_made          boolean default false,
  payment_amount        numeric(10,2),
  payment_date          date,
  vehicle_returned      date,
  closed_date           date,

  constraint repair_cases_body_shop_id_fkey
    foreign key (body_shop_id) references body_shops(id)
);


-- ----------------------------------------------------------------------------
-- status_history  (base 0001)
--   Append-only audit trail: every status change is logged for accountability.
-- ----------------------------------------------------------------------------
create table status_history (
  id           uuid primary key default gen_random_uuid(),
  case_id      uuid,                      -- FK -> repair_cases(id) ON DELETE CASCADE
  from_status  repair_status,
  to_status    repair_status not null,
  changed_by   text,
  note         text,
  changed_at   timestamptz default now(),
  constraint status_history_case_id_fkey
    foreign key (case_id) references repair_cases(id) on delete cascade
);


-- ----------------------------------------------------------------------------
-- case_estimates  (migration 0004)
--   Estimate documents (files) from body shop and appraiser, held in the
--   private 'estimates' Storage bucket. One row per uploaded file.
-- ----------------------------------------------------------------------------
create table case_estimates (
  id           uuid primary key default gen_random_uuid(),
  case_id      uuid not null,             -- FK -> repair_cases(id) ON DELETE CASCADE
  source       text not null check (source in ('body_shop', 'appraiser')),
  file_path    text not null,
  file_name    text not null,
  mime_type    text,
  file_size    bigint,
  amount       numeric(10,2),
  note         text,
  uploaded_by  text,
  created_at   timestamptz default now(),
  constraint case_estimates_case_id_fkey
    foreign key (case_id) references repair_cases(id) on delete cascade
);


-- ----------------------------------------------------------------------------
-- case_payments  (migration 0006; + direction 0016)
--   Payment records, each with a proof document in the private 'payments'
--   Storage bucket. direction distinguishes money received vs money paid out.
-- ----------------------------------------------------------------------------
create table case_payments (
  id           uuid primary key default gen_random_uuid(),
  case_id      uuid not null,             -- FK -> repair_cases(id) ON DELETE CASCADE
  amount       numeric(10,2),
  paid_on      date,
  method       text,
  file_path    text not null,
  file_name    text not null,
  mime_type    text,
  file_size    bigint,
  note         text,
  uploaded_by  text,
  created_at   timestamptz default now(),
  direction    text not null default 'inbound'      -- added 0016
                 check (direction in ('inbound', 'outbound')),
  constraint case_payments_case_id_fkey
    foreign key (case_id) references repair_cases(id) on delete cascade
);


-- ----------------------------------------------------------------------------
-- case_notes  (migration 0009; + author_role & shared_with_shop 0023)
--   Free-text notes log per case. author_role + shared_with_shop govern whether
--   a body-shop portal user can see a given note (internal staff notes stay hidden).
-- ----------------------------------------------------------------------------
create table case_notes (
  id                uuid primary key default gen_random_uuid(),
  case_id           uuid not null,        -- FK -> repair_cases(id) ON DELETE CASCADE
  body              text not null,
  created_by        text,
  created_at        timestamptz default now(),
  author_role       text not null default 'staff'   -- added 0023
                      check (author_role in ('staff', 'body_shop')),
  shared_with_shop  boolean not null default false,  -- added 0023
  constraint case_notes_case_id_fkey
    foreign key (case_id) references repair_cases(id) on delete cascade
);


-- ----------------------------------------------------------------------------
-- documents  (migration 0015)
--   Shared documents table. Every upload point records its compressed file here,
--   keyed by (module, record_id). record_id is a POLYMORPHIC reference (e.g. an
--   ntta_logs id or a repair_cases id) and is intentionally NOT a DB foreign key.
--   Files live in the private 'documents' Storage bucket.
-- ----------------------------------------------------------------------------
create table documents (
  id             uuid primary key default gen_random_uuid(),
  created_at     timestamptz default now(),
  module         text not null,           -- 'ntta' | 'repairs' | 'damage_report' | future modules
  record_id      uuid not null,           -- logical ref -> owning row's id (NOT an FK constraint)
  path           text not null,           -- path within the 'documents' Storage bucket
  original_name  text not null,           -- filename the user uploaded (display + download)
  mime_type      text not null,           -- content type of the stored compressed file
  size_bytes     bigint not null,
  uploaded_by    text
);


-- ----------------------------------------------------------------------------
-- ntta_logs  (migration 0015)
--   NTTA toll leakage module. Every toll is money that left the company; it is
--   either absorbed (write-off) or should be charged back to the customer when a
--   booking was open. `category` is a STORED GENERATED column derived from
--   booking_opened.
-- ----------------------------------------------------------------------------
create table ntta_logs (
  id                    uuid primary key default gen_random_uuid(),
  created_at            timestamptz default now(),
  log_date              date not null default current_date,
  amount                numeric(10,2) not null,       -- what the toll cost us
  booking_opened        boolean not null default false,
  category              ntta_category generated always as (
                          case when booking_opened then 'chargeback'::ntta_category
                               else 'absorbed_expense'::ntta_category end
                        ) stored,
  -- Booking branch only (required in the form when booking_opened = true)
  driver_name           text,
  license_plate         text,
  vin                   text,
  toll_tag_id           text,
  charge_to_customer    numeric(10,2),                -- amount to bill the customer
  incidental_completed  boolean default false,
  booking_reference     text,
  notes                 text
);


-- ----------------------------------------------------------------------------
-- case_updates  (migration 0017; + source & source_email_id 0024)
--   Inbound/outbound contact log per case, per external party. The newest
--   inbound row per party is "the last update from outside". Rows can be
--   auto-ingested from Gmail (source='gmail', source_email_id set).
-- ----------------------------------------------------------------------------
create table case_updates (
  id              uuid primary key default gen_random_uuid(),
  case_id         uuid not null,          -- FK -> repair_cases(id) ON DELETE CASCADE
  party           text not null
                    check (party in ('adjuster', 'appraiser', 'body_shop', 'owner', 'other')),
  direction       text not null default 'inbound'
                    check (direction in ('inbound', 'outbound')),
  channel         text
                    check (channel in ('call', 'email', 'voicemail', 'text', 'portal', 'in_person', 'other')),
  summary         text not null,
  occurred_on     date not null default current_date,
  created_by      text,
  created_at      timestamptz default now(),
  source          text not null default 'manual'      -- added 0024
                    check (source in ('manual', 'gmail')),
  source_email_id uuid,                                -- added 0024; FK -> inbound_emails(id) ON DELETE SET NULL
                                                       --   (constraint added after inbound_emails below)
  constraint case_updates_case_id_fkey
    foreign key (case_id) references repair_cases(id) on delete cascade
);


-- ----------------------------------------------------------------------------
-- gmail_connections  (migration 0024; token cols bytea->text 0025;
--   sweep_cadence & last_swept_at 0026)
--   Connected Gmail mailboxes for email->case routing. The encrypted refresh
--   token (AES-256-GCM, base64 text) is server-only. Staff-read only; all writes
--   via the service-role client.
-- ----------------------------------------------------------------------------
create table gmail_connections (
  id                 uuid primary key default gen_random_uuid(),
  email_address      text not null unique,
  google_sub         text,
  refresh_token_enc  text,                 -- was bytea (0024); changed to base64 text (0025)
  token_iv           text,                 -- was bytea (0024); changed to base64 text (0025)
  token_tag          text,                 -- was bytea (0024); changed to base64 text (0025)
  scope              text not null default 'https://www.googleapis.com/auth/gmail.readonly',
  last_history_id    text,
  last_synced_at     timestamptz,
  last_error         text,
  needs_reauth       boolean not null default false,
  active             boolean not null default true,
  connected_by       text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  sweep_cadence      text not null default 'off'       -- added 0026
                       check (sweep_cadence in ('off', 'daily', 'weekly')),
  last_swept_at      timestamptz                       -- added 0026
);


-- ----------------------------------------------------------------------------
-- inbound_emails  (migration 0024; + attachments 0027)
--   Ingested-email ledger / review queue. Each row records the routing decision
--   (route/queue/skip), the match attempt and confidence, and (0027) attachment
--   metadata. Staff-read only; writes via service-role client.
-- ----------------------------------------------------------------------------
create table inbound_emails (
  id               uuid primary key default gen_random_uuid(),
  connection_id    uuid not null,         -- FK -> gmail_connections(id) ON DELETE CASCADE
  gmail_message_id text not null unique,
  gmail_thread_id  text,
  from_email       text,
  from_name        text,
  subject          text,
  snippet          text,                  -- sanitized, UI-only; the drafter never reads it
  received_at      timestamptz not null,
  action           text not null check (action in ('route', 'queue', 'skip')),
  matched_case_id  uuid,                  -- FK -> repair_cases(id) ON DELETE SET NULL
  matched_party    text
                     check (matched_party in ('adjuster', 'appraiser', 'body_shop', 'owner', 'other')),
  confidence       integer not null default 0,
  confidence_tier  text check (confidence_tier in ('HIGH', 'MEDIUM', 'LOW', 'NONE')),
  match_reason     jsonb,
  case_update_id   uuid,                  -- FK -> case_updates(id) ON DELETE SET NULL
  status           text not null default 'unrouted'
                     check (status in ('matched', 'unrouted', 'ignored', 'error')),
  error            text,
  processed_at     timestamptz,
  created_at       timestamptz not null default now(),
  attachments      jsonb,                 -- added 0027; auto-filed/queued attachment metadata
  constraint inbound_emails_connection_id_fkey
    foreign key (connection_id) references gmail_connections(id) on delete cascade,
  constraint inbound_emails_matched_case_id_fkey
    foreign key (matched_case_id) references repair_cases(id) on delete set null,
  constraint inbound_emails_case_update_id_fkey
    foreign key (case_update_id) references case_updates(id) on delete set null
);


-- ----------------------------------------------------------------------------
-- gmail_ignored_messages  (migration 0028)
--   Tombstone for emails a staff member ignored. "Ignore" hard-deletes the
--   inbound_emails row; this remembers the Gmail message id so the next
--   newer_than:7d sync doesn't re-pull and re-queue it. Staff-read only.
-- ----------------------------------------------------------------------------
create table gmail_ignored_messages (
  gmail_message_id  text primary key,
  ignored_at        timestamptz not null default now()
);


-- ----------------------------------------------------------------------------
-- Deferred foreign key, closes the case_updates <-> inbound_emails cycle
-- (migration 0024 added this column + FK after inbound_emails existed).
-- ----------------------------------------------------------------------------
alter table case_updates
  add constraint case_updates_source_email_id_fkey
  foreign key (source_email_id) references inbound_emails(id) on delete set null;


-- ============================================================================
-- SECTION 3, TRIGGERS & FUNCTIONS (schema support)
-- ============================================================================

-- Keep updated_at fresh on every update (app-side also sets it; this is a
-- safety net). search_path pinned to '' per Supabase advisor (migration 0003).
create or replace function set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger repair_cases_set_updated_at
  before update on repair_cases
  for each row
  execute function set_updated_at();

-- Every new auth user gets a staff profile by default (invite flow overrides).
-- (migration 0018; exposure hardened in 0020, revoked from anon/authenticated.)
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, role) values (new.id, 'staff')
  on conflict (id) do nothing;
  return new;
end; $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- ============================================================================
-- SECTION 4, INDEXES (all CREATE INDEX statements from the migrations)
-- ============================================================================

-- repair_cases (base 0001; body_shop_id 0018)
create index idx_repair_cases_status         on repair_cases (status);
create index idx_repair_cases_coordinator    on repair_cases (coordinator);
create index idx_repair_cases_next_follow_up on repair_cases (next_follow_up);
create index idx_repair_cases_body_shop_id   on repair_cases (body_shop_id);

-- status_history (base 0001)
create index idx_status_history_case_id      on status_history (case_id);

-- case_estimates (0004)
create index idx_case_estimates_case_id      on case_estimates (case_id);

-- case_payments (0006)
create index idx_case_payments_case_id       on case_payments (case_id);

-- case_notes (0009)
create index idx_case_notes_case_id          on case_notes (case_id);

-- ntta_logs + documents (0015)
create index idx_ntta_logs_log_date          on ntta_logs (log_date);
create index idx_ntta_logs_booking_incidental
  on ntta_logs (booking_opened, incidental_completed);
create index idx_documents_module_record     on documents (module, record_id);

-- case_updates (0017)
create index idx_case_updates_case_id        on case_updates (case_id);
create index idx_case_updates_case_party     on case_updates (case_id, party, occurred_on desc);

-- body_shops (0018), unique, case-insensitive name
create unique index idx_body_shops_name_lower on body_shops (lower(name));

-- inbound_emails (0024)
create index idx_inbound_emails_status       on inbound_emails (status, received_at desc);
create index idx_inbound_emails_case         on inbound_emails (matched_case_id);
create index idx_inbound_emails_connection   on inbound_emails (connection_id);


-- ============================================================================
-- SECTION 5, ROW-LEVEL SECURITY
-- ============================================================================
-- RLS is ENABLED on every public table below. This section captures the FINAL
-- policy state after all 28 migrations (RLS began as a permissive "any
-- authenticated user" model in 0002, then was locked down to a role-aware model
-- in 0018-0023; the Gmail tables in 0024/0028 are staff-read-only from the
-- start).
--
--   alter table profiles               enable row level security;
--   alter table body_shops             enable row level security;
--   alter table repair_cases           enable row level security;
--   alter table status_history         enable row level security;
--   alter table case_estimates         enable row level security;
--   alter table case_payments          enable row level security;
--   alter table case_notes             enable row level security;
--   alter table documents              enable row level security;
--   alter table ntta_logs              enable row level security;
--   alter table case_updates           enable row level security;
--   alter table gmail_connections      enable row level security;
--   alter table inbound_emails         enable row level security;
--   alter table gmail_ignored_messages enable row level security;
--
-- ----------------------------------------------------------------------------
-- 5a. Helper functions (SECURITY DEFINER, search_path pinned), let a policy
--     read the caller's role/shop and case ownership WITHOUT recursive RLS.
-- ----------------------------------------------------------------------------
create or replace function public.auth_is_staff()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.role = 'staff'
  );
$$;

create or replace function public.auth_body_shop_id()
returns uuid language sql stable security definer set search_path = '' as $$
  select p.body_shop_id from public.profiles p where p.id = (select auth.uid());
$$;

-- RLS subqueries are themselves RLS-filtered, so a shop (staff-only on
-- repair_cases) can't verify its own case ownership inline. This definer helper
-- can see the case row to decide ownership (migration 0022).
create or replace function public.auth_owns_case(p_case_id text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.repair_cases c
    where c.id::text = p_case_id and c.body_shop_id = public.auth_body_shop_id()
  );
$$;

-- Grants: these helpers are granted to `authenticated` only (revoked from
-- anon/public). handle_new_user is revoked from the REST API entirely (0020).

-- ----------------------------------------------------------------------------
-- 5b. Staff-only tables, every operation requires public.auth_is_staff().
--     Body-shop users get NO policy here, so RLS default-denies them.
--     Applies to: repair_cases, status_history, case_payments, case_updates,
--     ntta_logs. (status_history is additionally append-only: select+insert,
--     no update/delete policy.) Pattern (shown for repair_cases):
-- ----------------------------------------------------------------------------
create policy "cases staff select" on public.repair_cases
  for select to authenticated using (public.auth_is_staff());
create policy "cases staff insert" on public.repair_cases
  for insert to authenticated with check (public.auth_is_staff());
create policy "cases staff update" on public.repair_cases
  for update to authenticated using (public.auth_is_staff()) with check (public.auth_is_staff());
create policy "cases staff delete" on public.repair_cases
  for delete to authenticated using (public.auth_is_staff());
-- ... identical staff-only policies exist for status_history (select/insert
--     only), case_payments (all four), case_updates (all four), ntta_logs
--     (all four). ntta_logs is staff-only by design, shops never see tolls.

-- ----------------------------------------------------------------------------
-- 5c. Shop-scoped tables, staff get full access; a shop is limited to rows
--     tied to its OWN cases via auth_owns_case(...).
-- ----------------------------------------------------------------------------

-- case_notes: shop reads its own cases' notes that are either shop-authored or
-- explicitly shared; a shop may insert only body_shop-authored notes on its
-- cases; only staff may delete. (0023)
create policy "notes select" on public.case_notes for select to authenticated
  using (
    public.auth_is_staff()
    or (public.auth_owns_case(case_notes.case_id::text)
        and (case_notes.author_role = 'body_shop' or case_notes.shared_with_shop))
  );
create policy "notes insert" on public.case_notes for insert to authenticated
  with check (
    public.auth_is_staff()
    or (case_notes.author_role = 'body_shop'
        and public.auth_owns_case(case_notes.case_id::text))
  );
create policy "notes staff delete" on public.case_notes for delete to authenticated
  using (public.auth_is_staff());

-- case_estimates: staff full; a shop may read AND insert estimates (body-shop
-- and appraiser) on its own cases; update/delete staff-only. (final form 0023)
create policy "estimates select" on public.case_estimates for select to authenticated
  using (public.auth_is_staff() or public.auth_owns_case(case_estimates.case_id::text));
create policy "estimates insert" on public.case_estimates for insert to authenticated
  with check (public.auth_is_staff() or public.auth_owns_case(case_estimates.case_id::text));
create policy "estimates update staff" on public.case_estimates for update to authenticated
  using (public.auth_is_staff()) with check (public.auth_is_staff());
create policy "estimates delete staff" on public.case_estimates for delete to authenticated
  using (public.auth_is_staff());

-- documents: staff full; a shop may read/insert only 'damage_report' docs
-- attached to its own cases (pinned to that module so other case docs can't
-- leak to shops); update/delete staff-only. (final form 0023)
create policy "documents select" on public.documents for select to authenticated
  using (public.auth_is_staff()
         or (documents.module = 'damage_report' and public.auth_owns_case(documents.record_id::text)));
create policy "documents insert" on public.documents for insert to authenticated
  with check (public.auth_is_staff()
         or (documents.module = 'damage_report' and public.auth_owns_case(documents.record_id::text)));
create policy "documents update staff" on public.documents for update to authenticated
  using (public.auth_is_staff()) with check (public.auth_is_staff());
create policy "documents delete staff" on public.documents for delete to authenticated
  using (public.auth_is_staff());

-- ----------------------------------------------------------------------------
-- 5d. Identity tables, profiles & body_shops.
-- ----------------------------------------------------------------------------
-- profiles: a user reads their own row (or any, if staff); only staff write.
create policy "profiles read own or staff" on public.profiles for select to authenticated
  using (id = (select auth.uid()) or public.auth_is_staff());
create policy "profiles staff insert" on public.profiles for insert to authenticated
  with check (public.auth_is_staff());
create policy "profiles staff update" on public.profiles for update to authenticated
  using (public.auth_is_staff()) with check (public.auth_is_staff());
create policy "profiles staff delete" on public.profiles for delete to authenticated
  using (public.auth_is_staff());

-- body_shops: staff read all; a shop reads only its own row; only staff write.
create policy "body_shops read staff or own" on public.body_shops for select to authenticated
  using (public.auth_is_staff() or id = public.auth_body_shop_id());
create policy "body_shops staff insert" on public.body_shops for insert to authenticated
  with check (public.auth_is_staff());
create policy "body_shops staff update" on public.body_shops for update to authenticated
  using (public.auth_is_staff()) with check (public.auth_is_staff());
create policy "body_shops staff delete" on public.body_shops for delete to authenticated
  using (public.auth_is_staff());

-- ----------------------------------------------------------------------------
-- 5e. Gmail routing tables, staff SELECT only; no write policy, so all writes
--     must go through the service-role client (which bypasses RLS). INSERT/
--     UPDATE/DELETE are also explicitly revoked from anon/authenticated.
-- ----------------------------------------------------------------------------
create policy "gmail_connections staff select" on public.gmail_connections
  for select to authenticated using (public.auth_is_staff());
create policy "inbound_emails staff select" on public.inbound_emails
  for select to authenticated using (public.auth_is_staff());
create policy "gmail_ignored_messages staff select" on public.gmail_ignored_messages
  for select to authenticated using (public.auth_is_staff());

-- ----------------------------------------------------------------------------
-- 5f. Body-shop portal surface, a shop never touches base tables directly.
-- ----------------------------------------------------------------------------
-- Safe read view: only non-sensitive columns, only the caller's shop. It is
-- SECURITY DEFINER (security_invoker = false) so it can read the staff-only
-- repair_cases, but its WHERE clause pins it to the caller's shop. Granted to
-- authenticated only. (migration 0019)
create or replace view public.shop_cases with (security_invoker = false) as
  select
    c.id, c.vin, c.vehicle_name, c.owner_name, c.status, c.current_location,
    c.date_in, c.repair_start, c.eta, c.claim_number, c.claim_filed,
    c.adjuster_name, c.adjuster_contact, c.appraiser_name, c.appraiser_contact,
    c.supplement_needed, c.supplement_status, c.incident_description,
    c.body_shop_estimate, c.body_shop_id
  from public.repair_cases c
  where c.body_shop_id = public.auth_body_shop_id();
-- revoke all on public.shop_cases from public; grant select to authenticated;

-- Column-whitelisted write for shops: only repair_start / eta, only on their
-- own cases. Granted to authenticated; revoked from anon. (migration 0019)
create or replace function public.shop_update_progress(
  p_case_id uuid,
  p_repair_start date default null,
  p_eta date default null
) returns void language plpgsql security definer set search_path = '' as $$
declare v_shop uuid;
begin
  v_shop := public.auth_body_shop_id();
  if v_shop is null then raise exception 'not authorized: not a body-shop user'; end if;
  update public.repair_cases
    set repair_start = coalesce(p_repair_start, repair_start),
        eta = coalesce(p_eta, eta),
        updated_at = now()
  where id = p_case_id and body_shop_id = v_shop;
  if not found then raise exception 'case not found for this shop'; end if;
end; $$;


-- ============================================================================
-- SECTION 6, SUPABASE STORAGE BUCKETS
-- ============================================================================
-- Three PRIVATE Storage buckets back the app's file uploads (public = false):
--
--   'estimates', body-shop / appraiser estimate files   (case_estimates)
--   'payments', payment proof files (PDF/JPEG)          (case_payments)
--   'documents', all shared compressed docs, incl. NTTA receipts & repair
--                  damage reports                          (documents)
--
-- Example (as created in migration 0004; 'payments' in 0006, 'documents' in 0015):
--   insert into storage.buckets (id, name, public)
--   values ('estimates', 'estimates', false) on conflict (id) do nothing;
--
-- storage.objects RLS (final state, migrations 0021-0023):
--   - Staff: full read/insert/update/delete across all three buckets.
--   - Shops: read/insert only under their OWN cases, scoped by the case id
--     embedded in the object path, via auth_owns_case(...):
--       estimates:  path = {caseId}/{source}/...                 -> folder[1] = caseId
--       documents:  path = {module}/{yyyy}/{mm}/{caseId}/...      -> folder[1] must be
--                   'damage_report' and folder[4] = caseId
--     (shops have no 'payments' bucket access).


-- ============================================================================
-- APPENDIX, SOURCE MIGRATIONS (authoritative, in order)
-- ============================================================================
-- This consolidated file was compiled from supabase/migrations/, verified
-- against lib/database.types.ts. The migrations, in order, are:
--
--   20260620000001_create_fleet_repair_schema.sql       base: enums, repair_cases,
--                                                        status_history, set_updated_at
--   20260620000002_enable_rls_policies.sql               initial permissive RLS
--   20260620000003_harden_function_search_path.sql       pin set_updated_at search_path
--   20260620000004_add_case_estimate_files.sql           case_estimates + 'estimates' bucket
--   20260620000005_rename_vehicle_fields.sql             vehicle_plate->vehicle_number,
--                                                        fleet_id->vehicle_name
--   20260620000006_add_case_payments.sql                 case_payments + 'payments' bucket
--   20260620000007_add_vin_field.sql                     repair_cases.vin
--   20260620000008_drop_vehicle_number.sql               drop repair_cases.vehicle_number
--   20260620000009_add_case_notes.sql                    case_notes
--   20260620000010_add_follow_up_manual.sql              repair_cases.follow_up_manual
--   20260620000011_add_total_loss_status.sql             repair_status += 'total_loss'
--   20260620000012_add_settlement_fields.sql             total_loss_date, settlement_*
--   20260620000013_add_total_loss_estimate.sql           repair_cases.total_loss_estimate
--   20260620000014_add_follow_up_done.sql                repair_cases.follow_up_done
--   20260620000015_add_ntta_and_documents.sql            ntta_category, ntta_logs,
--                                                        documents + 'documents' bucket
--   20260620000016_add_payment_direction.sql             case_payments.direction
--   20260620000017_add_case_updates.sql                  case_updates
--   20260620000018_add_body_shop_roles_foundation.sql    body_shops, profiles,
--                                                        repair_cases.body_shop_id, helpers
--   20260620000019_body_shop_rls_lockdown.sql            role-aware RLS, shop_cases view,
--                                                        shop_update_progress RPC
--   20260620000020_harden_body_shop_function_grants.sql  tighten definer-function grants
--   20260620000021_body_shop_storage_lockdown.sql        storage.objects RLS by role/case
--   20260620000022_fix_shop_ownership_checks.sql         auth_owns_case helper + rewrites
--   20260620000023_shop_notes_and_appraiser_estimates.sql case_notes.author_role/
--                                                        shared_with_shop, policy hardening
--   20260620000024_add_gmail_routing.sql                 gmail_connections, inbound_emails,
--                                                        case_updates.source/source_email_id
--   20260620000025_gmail_token_text.sql                  gmail token cols bytea -> text
--   20260620000026_gmail_sweep_cadence.sql               gmail_connections.sweep_cadence,
--                                                        last_swept_at
--   20260620000027_inbound_email_attachments.sql         inbound_emails.attachments
--   20260620000028_gmail_ignored_messages.sql            gmail_ignored_messages
-- ============================================================================

-- Minimal local stand-in for the Supabase schema, with SYNTHETIC data only.
-- Used by db_test.sh; never run against production.
create role anon nologin;
create role authenticated nologin;
grant usage on schema public to anon, authenticated;
create schema auth;
create table auth.users (id uuid primary key, email text, email_confirmed_at timestamptz, created_at timestamptz default now());
create function auth.uid() returns uuid language sql stable
  as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;

create table public.profiles (id uuid primary key default gen_random_uuid(), email text unique not null,
  name text not null, role text not null default 'youth', linked_id text, active boolean not null default true,
  created_at timestamptz default now());
create table public.adults (id text primary key, name text, is_admin boolean default false);
create table public.site_config (id text primary key, value text);
create table public.youth (id text primary key, name text, el_enrolled boolean);
create table public.workshop_attendance (id bigserial primary key, youth_id text, workshop_id int);
create table public.youth_compliance (id bigserial primary key, youth_id text, waiver boolean);
create table public.adult_compliance (id bigserial primary key, adult_id text, note text);
create table public.program_settings (program_id text primary key, cert_notes text);
create table public.gcc_roster (id bigserial primary key, name text);
do $$ declare t text; begin
  foreach t in array array['adult_scrabble_sessions','event_registrations','event_volunteers','name_aliases',
    'pending_entries','program_attendance','program_cancellations','program_session_meta','program_volunteers',
    'scrabble_scores','scrabble_sessions','scrabble_state','service_project_participants','service_projects',
    'workshop_cancellations','workshop_conducted'] loop
    execute format('create table public.%I (id bigserial primary key, note text)', t);
    execute format('insert into public.%I(note) values (%L)', t, 'synthetic');
  end loop;
end $$;
-- Games & Crafts: stand-in editor check (admins only) with its own policy
create function public.gcc_is_editor() returns boolean language sql stable security definer set search_path = ''
  as $$ select exists (select 1 from public.profiles p join auth.users u on lower(u.email) = lower(p.email)
                        where u.id = auth.uid() and p.role = 'admin') $$;
alter table public.gcc_roster enable row level security;
create policy gcc_editor_all on public.gcc_roster for all to authenticated using (public.gcc_is_editor()) with check (public.gcc_is_editor());
grant all on public.gcc_roster to anon, authenticated;
create table public.gcc_quarters (id text primary key, label text, status_changed_by_email text);
alter table public.gcc_quarters enable row level security;
create policy gcc_quarters_read on public.gcc_quarters for select to authenticated using (true);
grant select on public.gcc_quarters to authenticated;
insert into public.gcc_quarters values ('q1', 'Synthetic Q1', 'staff@example.test');
grant usage, select on all sequences in schema public to authenticated;

-- Synthetic people
insert into auth.users(id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@example.test',   now()),
  ('00000000-0000-0000-0000-00000000000b', 'adult@example.test',   now()),
  ('00000000-0000-0000-0000-00000000000c', 'youth@example.test',   now()),
  ('00000000-0000-0000-0000-00000000000d', 'partner@example.test', now()),
  ('00000000-0000-0000-0000-00000000000e', 'partner2@example.test', now()),
  ('00000000-0000-0000-0000-00000000000f', 'partnerx@example.test', null);
insert into public.adults values ('adult_a', 'Synthetic Adult', false), ('admin_a', 'Synthetic Admin', true);
insert into public.profiles(email, name, role, linked_id, active) values
  ('admin@example.test', 'Synthetic Admin', 'admin', 'admin_a', true),
  ('adult@example.test', 'Synthetic Adult', 'adult', 'adult_a', true),
  ('youth@example.test', 'Synthetic Youth', 'youth', 'yn_test', true),
  ('partner@example.test', 'Synthetic Partner', 'el_partner', null, true),
  -- a partner whose linked_id points at an admin adult must still not be admin
  ('partner2@example.test', 'Synthetic Partner Two', 'el_partner', 'admin_a', true),
  ('partnerx@example.test', 'Unconfirmed Partner', 'el_partner', null, true);
insert into public.youth values ('yn_test', 'Test Youth A', true), ('yn_test2', 'Test Youth B', true);
insert into public.workshop_attendance(youth_id, workshop_id) values ('yn_test', 1), ('yn_test2', 1);
insert into public.youth_compliance(youth_id, waiver) values ('yn_test', true);
insert into public.adult_compliance(adult_id, note) values ('adult_a', 'synthetic');
insert into public.program_settings values ('el_youth_archived', '[]');
insert into public.gcc_roster(name) values ('Test Youth A');
insert into public.site_config values ('home_content', '{}'), ('public_summary', '{"v":1}'),
  ('admin_only_setting', 'x'), ('el_partner_snapshot', '{"v":1,"active":["Test Youth A"]}');

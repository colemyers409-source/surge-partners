-- ============================================================
--  Surge Recruit — Supabase schema
--  Run once in the Supabase SQL editor (project szdzbycppkavfwuzlljh).
--  Safe to re-run: everything is IF NOT EXISTS / OR REPLACE.
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- helpers ----------
create or replace function rp_gen_token() returns text language sql volatile as $$
  select left(translate(encode(sha256(convert_to(random()::text || clock_timestamp()::text || random()::text, 'UTF8')), 'base64'), '+/=', '-_'), 22)
$$;

create or replace function rp_touch() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

-- ---------- team members (recruiters / hosts) ----------
create table if not exists rp_team_members (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users(id) on delete cascade,
  name text not null,
  email text,
  role text not null default 'recruiter',       -- admin | recruiter
  is_host boolean not null default true,
  sms_enabled boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------- positions / openings ----------
create table if not exists rp_positions (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  position_type text not null default 'Life Insurance Sales Rep',
  team text not null default 'Surge Partners',
  location text default 'Fayetteville, AR',
  radius_mi int default 50,
  comp_min int, comp_max int,
  comp_type text default 'Commission Only',
  sales_type text default 'Full Cycle',           -- Full Cycle | AE / Closer
  licensing text default 'No license required',
  work_arrangement text default 'Remote',         -- Remote | Hybrid | In-person
  job_type text default 'Full Time',
  seniority text default 'Entry Level',
  industry text default 'Insurance',
  description text,
  active boolean not null default true,
  hiring_goal int default 4,
  created_at timestamptz not null default now()
);

-- ---------- candidates ----------
create table if not exists rp_candidates (
  id uuid primary key default gen_random_uuid(),
  token text unique not null default rp_gen_token(),
  first_name text not null,
  last_name text default '',
  email text,
  phone text,
  sms_capable boolean default true,
  timezone text default 'America/Chicago',
  status text not null default 'New',
  position_id uuid references rp_positions(id) on delete set null,
  team text default 'Surge Partners',
  assigned_to uuid references rp_team_members(id) on delete set null,
  referrer text,                                   -- affiliate / ?ref= name
  referrer_type text default 'Direct',             -- Direct | Affiliate | Indeed | ...
  source text default 'apply',
  resume_path text,                                -- storage path in bucket rp-resumes
  ai_score int,
  ai_strengths jsonb default '[]'::jsonb,
  ai_concerns jsonb default '[]'::jsonb,
  ai_summary text,
  notes text default '',
  dnc boolean not null default false,
  unread boolean not null default false,
  last_message_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists rp_candidates_status_idx on rp_candidates(status);
create index if not exists rp_candidates_created_idx on rp_candidates(created_at desc);
create index if not exists rp_candidates_phone_idx on rp_candidates(phone);

drop trigger if exists rp_candidates_touch on rp_candidates;
create trigger rp_candidates_touch before update on rp_candidates
  for each row execute function rp_touch();

-- ---------- status history (change log) ----------
create table if not exists rp_status_history (
  id bigint generated always as identity primary key,
  candidate_id uuid not null references rp_candidates(id) on delete cascade,
  from_status text, to_status text,
  changed_by text default 'system',
  created_at timestamptz not null default now()
);

create or replace function rp_log_status() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    insert into rp_status_history(candidate_id, from_status, to_status, changed_by)
      values (new.id, null, new.status, coalesce(current_setting('request.jwt.claims', true)::jsonb->>'email','system'));
  elsif new.status is distinct from old.status then
    insert into rp_status_history(candidate_id, from_status, to_status, changed_by)
      values (new.id, old.status, new.status, coalesce(current_setting('request.jwt.claims', true)::jsonb->>'email','system'));
  end if;
  return new;
end $$;
drop trigger if exists rp_candidates_log on rp_candidates;
create trigger rp_candidates_log after insert or update on rp_candidates
  for each row execute function rp_log_status();

-- ---------- messages (SMS thread) ----------
create table if not exists rp_messages (
  id bigint generated always as identity primary key,
  candidate_id uuid not null references rp_candidates(id) on delete cascade,
  direction text not null check (direction in ('in','out')),
  sender text default 'Surge Partners',            -- 'candidate' | 'ai' | team member name
  body text not null,
  delivery text default 'queued',                  -- queued | sent | delivered | failed | received
  created_at timestamptz not null default now()
);
create index if not exists rp_messages_cand_idx on rp_messages(candidate_id, created_at);

create or replace function rp_after_message() returns trigger language plpgsql as $$
begin
  update rp_candidates
     set last_message_at = new.created_at,
         unread = case when new.direction = 'in' then true else unread end
   where id = new.candidate_id;
  -- Phase 2 hook: outbound messages land in rp_outbox for the SMS worker (Twilio)
  if new.direction = 'out' then
    insert into rp_outbox(message_id, candidate_id, body) values (new.id, new.candidate_id, new.body);
  end if;
  return new;
end $$;

create table if not exists rp_outbox (
  id bigint generated always as identity primary key,
  message_id bigint references rp_messages(id) on delete cascade,
  candidate_id uuid references rp_candidates(id) on delete cascade,
  body text not null,
  status text not null default 'pending',          -- pending | sent | failed
  provider_id text, error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
drop trigger if exists rp_messages_after on rp_messages;
create trigger rp_messages_after after insert on rp_messages
  for each row execute function rp_after_message();

-- ---------- message templates (the automated sequence) ----------
create table if not exists rp_templates (
  key text primary key,
  label text not null,
  body text not null,
  sort int default 0
);
insert into rp_templates(key,label,body,sort) values
 ('applied','Application received',E'Hi {first_name},\n\nThanks for applying for the {position} role with Surge Partners. The hiring team will be reviewing your application and will reach out from this number with any updates.\n\nReply STOP to opt out.',1),
 ('accepted','Accepted → schedule interview',E'Hi {first_name},\n\nGreat news! We''ve reviewed your application for the {position} role and would love to move forward with the interview process.\n\nThe next step is to schedule a time with the hiring manager. You can do that here: {portal_link}\n\nReply STOP to opt out.',2),
 ('rejected','Not moving forward',E'Hi {first_name}, thanks for applying to Surge Partners. We''ve reviewed your application for the {position} role, and unfortunately it doesn''t quite meet the requirements we''re looking for right now. We encourage you to keep an eye on our careers page for future openings.\n\nReply STOP to opt out.',3),
 ('booked','Interview booked confirmation',E'Hi {first_name},\n\nSurge Partners here. Thanks for scheduling your interview with the hiring manager!\n\nYou can find all the details here: {portal_link}\n\nThey''re looking forward to meeting you.',4),
 ('reminder','Day-of reminder',E'Hi {first_name},\n\nJust a reminder that our meeting is today at {meeting_time}. You can join here: {portal_link}\n\nLooking forward to connecting!',5),
 ('nudge','Hasn''t booked yet',E'Hey {first_name},\n\nJust wanted to check in about your interview for the {position} role at Surge Partners. I noticed you haven''t booked a time yet, and that''s totally fine.\n\nWhenever you''re ready, you can pick a slot that works for you here: {portal_link}',6),
 ('missed','Missed interview → reschedule',E'Hi {first_name},\n\nSurge Partners here. We noticed you weren''t able to make your interview for the {position} position. We''d still really like to connect with you.\n\nYou can reschedule here: {portal_link}',7),
 ('personal','Personal note from Cole',E'Hello {first_name}! This is Cole Myers, Co-Founder of Surge Partners. Thanks for applying. I will be personally reviewing your application to ensure we did not overlook a great candidate.',8)
on conflict (key) do nothing;

-- ---------- meeting types & slots ----------
create table if not exists rp_meeting_types (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,                       -- Interview | NHO
  duration_min int not null default 30,
  location text default 'Virtual',
  join_url text,
  capacity int not null default 50,
  booking_window_days int not null default 7,
  cancel_cutoff_min int not null default 60,
  sort int default 0
);
insert into rp_meeting_types(name,duration_min,capacity,sort) values ('Interview',30,50,1),('NHO',30,1,2)
on conflict (name) do nothing;

create table if not exists rp_slots (
  id uuid primary key default gen_random_uuid(),
  meeting_type_id uuid not null references rp_meeting_types(id) on delete cascade,
  host_id uuid references rp_team_members(id) on delete set null,
  host_name text,
  starts_at timestamptz not null,
  duration_min int not null default 30,
  capacity int not null default 50,
  join_url text,
  created_at timestamptz not null default now()
);
create index if not exists rp_slots_start_idx on rp_slots(starts_at);

create table if not exists rp_meetings (
  id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references rp_candidates(id) on delete cascade,
  slot_id uuid references rp_slots(id) on delete set null,
  meeting_type_id uuid references rp_meeting_types(id),
  starts_at timestamptz not null,
  status text not null default 'scheduled',        -- scheduled | completed | qualified | missed | canceled
  disposition_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists rp_meetings_cand_idx on rp_meetings(candidate_id);
drop trigger if exists rp_meetings_touch on rp_meetings;
create trigger rp_meetings_touch before update on rp_meetings for each row execute function rp_touch();

-- ---------- affiliate click tracking ----------
create table if not exists rp_clicks (
  id bigint generated always as identity primary key,
  ref text, position_id uuid, landed_at timestamptz not null default now(), ua text
);

-- ---------- settings (branding) ----------
create table if not exists rp_settings (key text primary key, value jsonb not null default '{}'::jsonb);
insert into rp_settings(key,value) values
 ('brand','{"company":"Surge Partners","gradient_start":"#0b0b0b","gradient_end":"#c9a227","accent":"#d4af37"}'),
 ('portal','{"base_url":"","zoom_url":""}')
on conflict (key) do nothing;

-- ============================================================
--  Row level security
-- ============================================================
do $$ declare t text; begin
  foreach t in array array['rp_team_members','rp_positions','rp_candidates','rp_status_history','rp_messages','rp_outbox','rp_templates','rp_meeting_types','rp_slots','rp_meetings','rp_clicks','rp_settings'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists %I on %I', t||'_staff_all', t);
    execute format('create policy %I on %I for all to authenticated using (true) with check (true)', t||'_staff_all', t);
  end loop;
end $$;

-- anon may read positions (for the apply form) and log clicks
drop policy if exists rp_positions_public_read on rp_positions;
create policy rp_positions_public_read on rp_positions for select to anon using (active);
drop policy if exists rp_clicks_public_insert on rp_clicks;
create policy rp_clicks_public_insert on rp_clicks for insert to anon with check (true);

-- ---------- resume storage bucket ----------
insert into storage.buckets (id, name, public) values ('rp-resumes','rp-resumes', false)
on conflict (id) do nothing;
drop policy if exists rp_resumes_anon_upload on storage.objects;
create policy rp_resumes_anon_upload on storage.objects for insert to anon with check (bucket_id = 'rp-resumes');
drop policy if exists rp_resumes_staff on storage.objects;
create policy rp_resumes_staff on storage.objects for all to authenticated using (bucket_id = 'rp-resumes') with check (bucket_id = 'rp-resumes');

-- ============================================================
--  Public RPCs (security definer) — used by apply.html and c.html
-- ============================================================

-- Public application form
create or replace function rp_apply(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid; tok text; pos rp_positions; ptitle text;
begin
  insert into rp_candidates(first_name,last_name,email,phone,position_id,referrer,referrer_type,source,resume_path,timezone)
  values (
    coalesce(p->>'first_name','') , coalesce(p->>'last_name',''),
    nullif(p->>'email',''), nullif(p->>'phone',''),
    nullif(p->>'position_id','')::uuid,
    nullif(p->>'ref',''), case when nullif(p->>'ref','') is null then 'Direct' else 'Affiliate' end,
    coalesce(p->>'source','apply'), nullif(p->>'resume_path',''), coalesce(p->>'timezone','America/Chicago'))
  returning id, token into cid, tok;
  select title into ptitle from rp_positions where id = nullif(p->>'position_id','')::uuid;
  -- queue the "applied" text
  insert into rp_messages(candidate_id,direction,sender,body)
  select cid,'out','ai', replace(replace(body,'{first_name}',coalesce(p->>'first_name','')),'{position}',coalesce(ptitle,'Entry Level Sales Representative'))
  from rp_templates where key='applied';
  return jsonb_build_object('id',cid,'token',tok);
end $$;
grant execute on function rp_apply(jsonb) to anon, authenticated;

-- Candidate portal payload
create or replace function rp_portal(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c rp_candidates; pos rp_positions; brand jsonb; result jsonb;
begin
  select * into c from rp_candidates where token = p_token;
  if not found then return jsonb_build_object('error','not_found'); end if;
  select * into pos from rp_positions where id = c.position_id;
  select value into brand from rp_settings where key='brand';
  result := jsonb_build_object(
    'candidate', jsonb_build_object('first_name',c.first_name,'status',c.status,'timezone',c.timezone,'dnc',c.dnc),
    'position', jsonb_build_object('title',coalesce(pos.title,'Entry Level Sales Representative'),'position_type',coalesce(pos.position_type,'Life Insurance Sales Rep')),
    'brand', coalesce(brand,'{}'::jsonb),
    'meeting_types', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'duration_min',duration_min,'location',location,'booking_window_days',booking_window_days,'sort',sort) order by sort),'[]'::jsonb) from rp_meeting_types),
    'meetings', (select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'type',t.name,'starts_at',m.starts_at,'status',m.status,'join_url',coalesce(s.join_url,t.join_url),'host',s.host_name) order by m.starts_at),'[]'::jsonb)
                 from rp_meetings m left join rp_meeting_types t on t.id=m.meeting_type_id left join rp_slots s on s.id=m.slot_id where m.candidate_id=c.id),
    'slots', (select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'type',t.name,'meeting_type_id',t.id,'starts_at',s.starts_at,'duration_min',s.duration_min,'host',s.host_name,
                 'open', s.capacity - (select count(*) from rp_meetings m where m.slot_id=s.id and m.status='scheduled')) order by s.starts_at),'[]'::jsonb)
              from rp_slots s join rp_meeting_types t on t.id=s.meeting_type_id
              where s.starts_at > now() and s.starts_at < now() + (t.booking_window_days||' days')::interval
                and s.capacity > (select count(*) from rp_meetings m where m.slot_id=s.id and m.status='scheduled'))
  );
  return result;
end $$;
grant execute on function rp_portal(text) to anon, authenticated;

-- Book a slot from the portal
create or replace function rp_book(p_token text, p_slot uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c rp_candidates; s rp_slots; t rp_meeting_types; mid uuid; taken int; ptitle text;
begin
  select * into c from rp_candidates where token = p_token;
  if not found then return jsonb_build_object('error','not_found'); end if;
  select * into s from rp_slots where id = p_slot;
  if not found or s.starts_at < now() then return jsonb_build_object('error','slot_unavailable'); end if;
  select * into t from rp_meeting_types where id = s.meeting_type_id;
  select count(*) into taken from rp_meetings where slot_id = s.id and status='scheduled';
  if taken >= s.capacity then return jsonb_build_object('error','slot_full'); end if;
  -- cancel any other scheduled meeting of the same type (reschedule)
  update rp_meetings set status='canceled' where candidate_id=c.id and meeting_type_id=t.id and status='scheduled';
  insert into rp_meetings(candidate_id,slot_id,meeting_type_id,starts_at) values (c.id,s.id,t.id,s.starts_at) returning id into mid;
  update rp_candidates set status = t.name||' Scheduled' where id=c.id;
  select title into ptitle from rp_positions where id=c.position_id;
  insert into rp_messages(candidate_id,direction,sender,body)
  select c.id,'out','ai', replace(replace(body,'{first_name}',c.first_name),'{position}',coalesce(ptitle,'Entry Level Sales Representative'))
  from rp_templates where key='booked';
  return jsonb_build_object('ok',true,'meeting_id',mid,'starts_at',s.starts_at);
end $$;
grant execute on function rp_book(text, uuid) to anon, authenticated;

-- Cancel from the portal
create or replace function rp_cancel(p_token text, p_meeting uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c rp_candidates; m rp_meetings; t rp_meeting_types;
begin
  select * into c from rp_candidates where token = p_token;
  if not found then return jsonb_build_object('error','not_found'); end if;
  select * into m from rp_meetings where id=p_meeting and candidate_id=c.id;
  if not found then return jsonb_build_object('error','not_found'); end if;
  select * into t from rp_meeting_types where id=m.meeting_type_id;
  if m.starts_at - (t.cancel_cutoff_min||' minutes')::interval < now() then return jsonb_build_object('error','too_late'); end if;
  update rp_meetings set status='canceled' where id=m.id;
  update rp_candidates set status = t.name||' Canceled' where id=c.id;
  return jsonb_build_object('ok',true);
end $$;
grant execute on function rp_cancel(text, uuid) to anon, authenticated;

-- Inbound SMS webhook target (Phase 2: called by the Twilio edge function with service role)
create or replace function rp_inbound_sms(p_from text, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c rp_candidates; digits text;
begin
  digits := right(regexp_replace(p_from,'\D','','g'),10);
  select * into c from rp_candidates where right(regexp_replace(coalesce(phone,''),'\D','','g'),10)=digits order by created_at desc limit 1;
  if not found then return jsonb_build_object('error','unknown_number'); end if;
  insert into rp_messages(candidate_id,direction,sender,body,delivery) values (c.id,'in','candidate',p_body,'received');
  if upper(trim(p_body)) in ('STOP','UNSUBSCRIBE','CANCEL','END','QUIT') then
    update rp_candidates set dnc=true where id=c.id;
  end if;
  return jsonb_build_object('ok',true,'candidate_id',c.id);
end $$;

-- Staff helper: mirror new rows from the existing recruiting-site `recruits` table into the pipeline
create or replace function rp_mirror_recruit() returns trigger language plpgsql security definer as $$
declare j jsonb := to_jsonb(new); nm text; fn text; ln text;
begin
  nm := coalesce(j->>'name', j->>'full_name', trim(coalesce(j->>'first_name','')||' '||coalesce(j->>'last_name','')));
  fn := split_part(nm,' ',1); ln := nullif(substr(nm, length(fn)+2),'');
  insert into rp_candidates(first_name,last_name,email,phone,referrer,referrer_type,source)
  values (coalesce(nullif(fn,''),'Applicant'), coalesce(ln,''), j->>'email', j->>'phone', j->>'ref', case when coalesce(j->>'ref','') = '' then 'Direct' else 'Affiliate' end, 'recruiting-site');
  return new;
exception when others then return new;
end $$;
do $$ begin
  if to_regclass('public.recruits') is not null then
    execute 'drop trigger if exists rp_mirror on recruits';
    execute 'create trigger rp_mirror after insert on recruits for each row execute function rp_mirror_recruit()';
  end if;
end $$;

-- Scoreboard RPC for the recruiter leaderboard
create or replace function rp_scoreboard() returns table(referrer text, clicks bigint, applicants bigint, interviews bigint, qualified bigint)
language sql security definer set search_path = public as $$
  with refs as (select distinct coalesce(referrer,'Direct') r from rp_candidates union select distinct coalesce(ref,'Direct') from rp_clicks)
  select r,
    (select count(*) from rp_clicks k where coalesce(k.ref,'Direct')=r),
    (select count(*) from rp_candidates c where coalesce(c.referrer,'Direct')=r),
    (select count(*) from rp_candidates c where coalesce(c.referrer,'Direct')=r and c.status like 'Interview%'),
    (select count(*) from rp_candidates c where coalesce(c.referrer,'Direct')=r and c.status in ('Interview Qualified','NHO Scheduled','NHO Qualified'))
  from refs order by 3 desc;
$$;
grant execute on function rp_scoreboard() to authenticated;

-- Auto-create a team member row for anyone who signs in
create or replace function rp_ensure_member() returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid := auth.uid(); em text; m rp_team_members;
begin
  if uid is null then return jsonb_build_object('error','no_auth'); end if;
  select email into em from auth.users where id=uid;
  select * into m from rp_team_members where user_id=uid;
  if not found then
    insert into rp_team_members(user_id,name,email,role)
    values (uid, coalesce(split_part(em,'@',1),'Recruiter'), em, case when (select count(*) from rp_team_members)=0 then 'admin' else 'recruiter' end)
    returning * into m;
  end if;
  return to_jsonb(m);
end $$;
grant execute on function rp_ensure_member() to authenticated;

-- Seed the two openings Cole runs today
insert into rp_positions(title,sales_type,licensing,work_arrangement,comp_min,comp_max)
select 'Closer - Entry Level','AE / Closer','Life and Health Insurance','Hybrid',85000,150000
where not exists (select 1 from rp_positions where title='Closer - Entry Level');
insert into rp_positions(title,sales_type,licensing,work_arrangement,comp_min,comp_max)
select 'Full Cycle - Entry Level','Full Cycle','No license required','Remote',85000,150000
where not exists (select 1 from rp_positions where title='Full Cycle - Entry Level');

-- ============================================================
--  v1.1 — map + ad-spend orders (SalesDraft "Order Candidates" equivalent)
-- ============================================================
alter table rp_positions add column if not exists lat double precision;
alter table rp_positions add column if not exists lng double precision;
alter table rp_positions add column if not exists requirements text default 'Authorized to work in the US · 18 or older · Mobile device · Home internet';
update rp_positions set lat=36.0626, lng=-94.1574 where lat is null and location ilike 'Fayetteville, AR%';

create table if not exists rp_orders (
  id uuid primary key default gen_random_uuid(),
  position_id uuid references rp_positions(id) on delete cascade,
  source text not null default 'Indeed',           -- Indeed | ZipRecruiter | Facebook | Other
  starts_on date not null default current_date,
  ends_on date not null default current_date + 30,
  budget numeric(10,2) not null default 0,
  spent numeric(10,2) not null default 0,
  target_hires int not null default 4,
  standard_conv numeric(5,2) not null default 11.3, -- committed conversion % (hiring standard)
  notes text,
  created_at timestamptz not null default now()
);
alter table rp_orders enable row level security;
drop policy if exists rp_orders_staff_all on rp_orders;
create policy rp_orders_staff_all on rp_orders for all to authenticated using (true) with check (true);
insert into rp_settings(key,value) values ('sourcing','{"benchmark_cost_per_applicant":19,"customer_avg_conv":11.3}') on conflict (key) do nothing;
-- ============================================================
--  v1.2 — Phase 2: texting + AI (edge function wiring)
-- ============================================================
alter table rp_meetings   add column if not exists reminded_at timestamptz;
alter table rp_candidates add column if not exists nudged_at timestamptz;
insert into rp_settings(key,value) values
 ('ai','{"enabled":true,"auto_accept":"score","accept_threshold":50}'),
 ('faq','{"text":"- Remote: yes, fully remote, work from home anywhere in the US.\n- Licensing: no license needed to start; we walk you through getting your Life & Health license (online course, usually 1-2 weeks).\n- Pay: commission only, on-target earnings $85k-$150k/yr; first-year agents typically earn as they close, with weekly pay.\n- Schedule: full time, set your own hours within our lead schedules; evenings and Saturdays are strongest.\n- Interview: a 30-minute video call with the hiring manager (Cole Myers or Joey Scariano), booked from your personal link.\n- Training: 10-day new agent training with daily Zooms after you are hired."}')
on conflict (key) do nothing;

create extension if not exists pg_net;
create extension if not exists pg_cron;

-- Trigger → sms-send when something lands in the outbox
create or replace function rp_call_edge(fn text, payload jsonb) returns void language plpgsql security definer as $$
begin
  perform net.http_post(
    url := 'https://szdzbycppkavfwuzlljh.supabase.co/functions/v1/' || fn,
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InN6ZHpieWNwcGthdmZ3dXpsbGpoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk1ODIxNzgsImV4cCI6MjA5NTE1ODE3OH0.Jw21eHChMDHlskSs2PegmBXLYNIQkjl8GByOIApadhA'),
    body := payload, timeout_milliseconds := 15000);
exception when others then null;
end $$;

create or replace function rp_outbox_notify() returns trigger language plpgsql as $$
begin perform rp_call_edge('sms-send', jsonb_build_object('outbox_id', new.id)); return new; end $$;
drop trigger if exists rp_outbox_after on rp_outbox;
create trigger rp_outbox_after after insert on rp_outbox for each row execute function rp_outbox_notify();

create or replace function rp_candidate_notify() returns trigger language plpgsql as $$
begin perform rp_call_edge('score-resume', jsonb_build_object('candidate_id', new.id)); return new; end $$;
drop trigger if exists rp_candidate_after on rp_candidates;
create trigger rp_candidate_after after insert on rp_candidates for each row execute function rp_candidate_notify();

-- Cron: reminders / no-shows / nudges / outbox sweep every 15 minutes
select cron.unschedule(jobid) from cron.job where jobname = 'rp_reminders';
select cron.schedule('rp_reminders', '*/15 * * * *', $$select rp_call_edge('reminders', '{}'::jsonb)$$);

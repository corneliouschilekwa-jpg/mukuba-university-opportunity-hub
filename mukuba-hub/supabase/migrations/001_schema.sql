-- Mukuba University Student Opportunity Hub — database schema
-- Run in Supabase SQL Editor (or `supabase db push`). Starts with NO data.

create extension if not exists pgcrypto;

-- ───────────── Enums ─────────────
create type user_role as enum ('student','company','admin','loan_officer');
create type app_status as enum ('pending','under_review','shortlisted','approved','rejected','more_info');
create type company_status as enum ('pending','approved','rejected','suspended');
create type job_status as enum ('pending','published','closed','rejected','expired');
create type employment_type as enum ('part_time','weekend','internship','temporary','attachment','volunteer','remote','holiday','full_time');
create type msg_kind as enum ('enquiry','complaint','suggestion','technical','loan_question','job_question');

-- ───────────── Profiles (one per auth user) ─────────────
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role user_role not null default 'student',
  full_name text not null,
  email text not null,
  phone text,
  student_number text unique,
  nrc_number text,
  school text,
  programme text,
  year_of_study int,
  gender text,
  availability jsonb default '{}'::jsonb,   -- {"days":["sat","sun"],"from":"08:00","to":"17:00"}
  suspended boolean not null default false,
  created_at timestamptz not null default now()
);

-- Helper functions (security definer so policies don't recurse)
create or replace function is_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin' and not suspended);
$$;
create or replace function is_loan_officer() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role in ('admin','loan_officer') and not suspended);
$$;

-- New auth user -> profile. Role is ALWAYS student or company here; admins are promoted manually in SQL.
create or replace function handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
declare r user_role := 'student';
begin
  if (new.raw_user_meta_data->>'account_type') = 'company' then r := 'company'; end if;
  insert into profiles (id, role, full_name, email, phone, student_number, nrc_number, school, programme, year_of_study, gender)
  values (new.id, r,
    coalesce(new.raw_user_meta_data->>'full_name',''), new.email,
    new.raw_user_meta_data->>'phone',
    nullif(new.raw_user_meta_data->>'student_number',''),
    new.raw_user_meta_data->>'nrc_number',
    new.raw_user_meta_data->>'school',
    new.raw_user_meta_data->>'programme',
    nullif(new.raw_user_meta_data->>'year_of_study','')::int,
    new.raw_user_meta_data->>'gender');
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

-- Prevent users from escalating their own role / suspension
create or replace function protect_profile_fields() returns trigger language plpgsql as $$
begin
  if auth.uid() is not null and not is_admin() then
    new.role := old.role; new.suspended := old.suspended; new.email := old.email;
  end if;
  return new;
end $$;
create trigger profiles_protect before update on profiles for each row execute function protect_profile_fields();

-- ───────────── Companies ─────────────
create table companies (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null unique references profiles(id) on delete cascade,
  name text not null,
  logo_path text,
  registration_number text not null,
  contact_person text not null,
  official_email text not null,
  phone text not null,
  address text not null,
  industry text not null,
  description text not null,
  website text,
  verification_doc_paths text[] default '{}',
  status company_status not null default 'pending',
  rejection_reason text,
  created_at timestamptz not null default now()
);

create or replace function protect_company_status() returns trigger language plpgsql as $$
begin
  if auth.uid() is not null and not is_admin() then new.status := old.status; new.rejection_reason := old.rejection_reason; end if;
  return new;
end $$;
create trigger companies_protect before update on companies for each row execute function protect_company_status();

-- ───────────── Jobs ─────────────
create table jobs (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  title text not null,
  description text not null,
  requirements text not null,
  qualifications text not null,
  location text not null,
  employment_type employment_type not null,
  working_days text[] not null default '{}',     -- mon..sun
  working_hours text not null,
  start_hour time,
  end_hour time,
  salary text,
  deadline date not null,
  positions int not null default 1 check (positions > 0),
  instructions text not null,
  status job_status not null default 'pending',
  rejection_reason text,
  created_at timestamptz not null default now()
);
create index jobs_status_idx on jobs(status, deadline);

create or replace function protect_job_status() returns trigger language plpgsql as $$
begin
  -- companies may only close their own job; publishing/rejecting is admin-only
  if auth.uid() is not null and not is_admin() then
    if new.status is distinct from old.status and not (new.status = 'closed') then new.status := old.status; end if;
    new.rejection_reason := old.rejection_reason;
  end if;
  return new;
end $$;
create trigger jobs_protect before update on jobs for each row execute function protect_job_status();

-- Companies can only insert jobs as 'pending' and only when approved
create or replace function enforce_job_insert() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not is_admin() then
    if not exists (select 1 from companies c where c.id = new.company_id and c.owner_id = auth.uid() and c.status = 'approved') then
      raise exception 'Your company must be verified before posting jobs';
    end if;
    new.status := 'pending';
  end if;
  return new;
end $$;
create trigger jobs_insert_guard before insert on jobs for each row execute function enforce_job_insert();

-- ───────────── Job applications ─────────────
create table job_applications (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references jobs(id) on delete cascade,
  student_id uuid not null references profiles(id) on delete cascade,
  cover_note text,
  status app_status not null default 'pending',
  company_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (job_id, student_id)
);

-- ───────────── Loan applications ─────────────
create sequence loan_ref_seq start 1000;
create table loan_applications (
  id uuid primary key default gen_random_uuid(),
  reference text unique not null default ('MUK-LN-' || to_char(now(),'YYYY') || '-' || nextval('loan_ref_seq')),
  student_id uuid not null references profiles(id) on delete cascade,
  -- personal
  full_name text not null, student_number text not null, nrc_number text not null,
  phone text not null, email text not null, school text not null, programme text not null,
  year_of_study int not null, residential_address text not null,
  -- business
  business_name text not null, business_type text not null, registration_status text not null,
  registration_number text, business_location text not null, business_description text not null,
  business_nature text not null, operating_status text not null check (operating_status in ('operating','proposed')),
  capital_required numeric(12,2) not null, amount_requested numeric(12,2) not null, funds_usage text not null,
  -- loan
  loan_reason text not null, business_idea text not null, expected_benefits text not null, growth_plan text not null,
  repayment_period_months int not null, repayment_plan text not null, repayment_source text not null,
  -- next of kin
  nok_name text not null, nok_relationship text not null, nok_phone text not null,
  nok_alt_phone text, nok_address text not null,
  -- documents (private storage paths)
  nrc_front_path text not null, nrc_back_path text not null, student_id_path text not null,
  passport_photo_path text not null, selfie_path text not null,
  -- consent / declaration
  consent_data boolean not null check (consent_data), declaration_accurate boolean not null check (declaration_accurate),
  consented_at timestamptz not null default now(),
  -- admin controlled
  status app_status not null default 'pending',
  admin_note text, rejection_reason text,
  approved_amount numeric(12,2), repayment_terms text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table loan_repayments (
  id uuid primary key default gen_random_uuid(),
  loan_id uuid not null references loan_applications(id) on delete cascade,
  amount numeric(12,2) not null check (amount > 0),
  paid_on date not null default current_date,
  note text,
  recorded_by uuid references profiles(id),
  created_at timestamptz not null default now()
);

-- Students may not touch admin-controlled loan fields
create or replace function protect_loan_fields() returns trigger language plpgsql as $$
begin
  if auth.uid() is not null and not is_loan_officer() then
    raise exception 'Only authorised administrators can modify a submitted loan application';
  end if;
  return new;
end $$;
create trigger loans_protect before update on loan_applications for each row execute function protect_loan_fields();

create or replace function force_loan_defaults() returns trigger language plpgsql as $$
begin
  new.status := 'pending'; new.approved_amount := null; new.repayment_terms := null;
  new.admin_note := null; new.rejection_reason := null; new.student_id := auth.uid();
  return new;
end $$;
create trigger loans_insert_defaults before insert on loan_applications for each row execute function force_loan_defaults();

-- ───────────── Posts / announcements ─────────────
create table posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references profiles(id),
  title text not null,
  body text not null,
  category text not null check (category in ('notice','job','funding','training','event','general')),
  pinned boolean not null default false,
  important boolean not null default false,
  attachment_path text,           -- public 'posts' bucket
  attachment_type text,           -- image | pdf
  created_at timestamptz not null default now()
);

-- ───────────── Messages & support ─────────────
create table threads (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references profiles(id) on delete cascade,
  kind msg_kind not null,
  subject text not null,
  resolved boolean not null default false,
  created_at timestamptz not null default now(),
  last_message_at timestamptz not null default now()
);
create table thread_messages (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references threads(id) on delete cascade,
  sender_id uuid not null references profiles(id),
  body text not null check (length(body) between 1 and 5000),
  created_at timestamptz not null default now()
);

-- Public help-centre contact form (visitors without accounts)
create table support_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references profiles(id),
  name text not null, email text not null, subject text not null,
  message text not null check (length(message) between 5 and 5000),
  resolved boolean not null default false,
  created_at timestamptz not null default now()
);

-- ───────────── Notifications ─────────────
create table notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  title text not null, body text, link text,
  read boolean not null default false,
  created_at timestamptz not null default now()
);
create index notif_user_idx on notifications(user_id, read, created_at desc);

create table activity_log (
  id bigserial primary key,
  actor_id uuid, action text not null, entity text, entity_id text,
  created_at timestamptz not null default now()
);

-- ───────────── Notification triggers ─────────────
create or replace function notify(uid uuid, t text, b text, l text) returns void language sql security definer set search_path = public as $$
  insert into notifications(user_id,title,body,link) values (uid,t,b,l);
$$;
create or replace function notify_admins(t text, b text, l text) returns void language sql security definer set search_path = public as $$
  insert into notifications(user_id,title,body,link) select id,t,b,l from profiles where role = 'admin';
$$;

create or replace function trg_loan_events() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform notify(new.student_id,'Loan application received','Your reference is '||new.reference||'. It is now pending review.','student.html#loans');
    perform notify_admins('New loan application', new.reference||' from '||new.full_name,'admin.html#loans');
  elsif new.status is distinct from old.status then
    perform notify(new.student_id,'Loan application update',
      new.reference||' is now: '||replace(new.status::text,'_',' ')||coalesce('. '||new.rejection_reason,''),'student.html#loans');
  end if;
  insert into activity_log(actor_id,action,entity,entity_id) values (auth.uid(), tg_op||' loan', 'loan', new.id::text);
  return new;
end $$;
create trigger loan_events after insert or update on loan_applications for each row execute function trg_loan_events();

create or replace function trg_company_events() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform notify_admins('Company verification request', new.name,'admin.html#companies');
  elsif new.status is distinct from old.status then
    perform notify(new.owner_id,'Company profile '||new.status, coalesce(new.rejection_reason,'Your company profile status changed.'),'company.html');
  end if;
  return new;
end $$;
create trigger company_events after insert or update on companies for each row execute function trg_company_events();

create or replace function trg_job_events() returns trigger language plpgsql security definer set search_path = public as $$
declare owner uuid;
begin
  select owner_id into owner from companies where id = new.company_id;
  if tg_op = 'INSERT' then
    perform notify_admins('Job awaiting approval', new.title,'admin.html#jobs');
  elsif new.status is distinct from old.status then
    if new.status = 'published' then
      perform notify(owner,'Job approved', new.title||' is now live.','company.html');
      insert into notifications(user_id,title,body,link)
        select id,'New job published', new.title,'jobs.html' from profiles where role = 'student' and not suspended;
    elsif new.status = 'rejected' then
      perform notify(owner,'Job rejected', new.title||coalesce(': '||new.rejection_reason,''),'company.html');
    end if;
  end if;
  return new;
end $$;
create trigger job_events after insert or update on jobs for each row execute function trg_job_events();

create or replace function trg_jobapp_events() returns trigger language plpgsql security definer set search_path = public as $$
declare owner uuid; jt text;
begin
  select c.owner_id, j.title into owner, jt from jobs j join companies c on c.id = j.company_id where j.id = new.job_id;
  if tg_op = 'INSERT' then
    perform notify(owner,'New applicant', 'A student applied for '||jt,'company.html#applicants');
  elsif new.status is distinct from old.status then
    perform notify(new.student_id,'Job application update', jt||': '||replace(new.status::text,'_',' '),'student.html#applications');
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger jobapp_events_i after insert on job_applications for each row execute function trg_jobapp_events();
create or replace function trg_jobapp_touch() returns trigger language plpgsql as $$ begin new.updated_at := now(); return new; end $$;
create trigger jobapp_touch before update on job_applications for each row execute function trg_jobapp_touch();
create trigger jobapp_events_u after update on job_applications for each row execute function trg_jobapp_events();

create or replace function trg_post_events() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.important then
    insert into notifications(user_id,title,body,link)
      select id,'Important: '||new.title, left(new.body,140),'news.html' from profiles where not suspended and role in ('student','company');
  end if;
  return new;
end $$;
create trigger post_events after insert on posts for each row execute function trg_post_events();

create or replace function trg_thread_events() returns trigger language plpgsql security definer set search_path = public as $$
declare t threads;
begin
  select * into t from threads where id = new.thread_id;
  update threads set last_message_at = now(), resolved = false where id = t.id and new.sender_id = t.owner_id;
  if new.sender_id = t.owner_id then
    perform notify_admins('New message: '||t.subject, left(new.body,120),'admin.html#messages');
  else
    perform notify(t.owner_id,'Reply from administration', left(new.body,120),'messages.html');
    update threads set last_message_at = now() where id = t.id;
  end if;
  return new;
end $$;
create trigger thread_events after insert on thread_messages for each row execute function trg_thread_events();

create or replace function trg_support_events() returns trigger language plpgsql security definer set search_path = public as $$
begin perform notify_admins('Support request: '||new.subject, new.name,'admin.html#support'); return new; end $$;
create trigger support_events after insert on support_requests for each row execute function trg_support_events();

-- Mark expired jobs (call daily via pg_cron or a Supabase scheduled function) and warn companies 3 days ahead
create or replace function expire_jobs() returns void language plpgsql security definer set search_path = public as $$
begin
  insert into notifications(user_id,title,body,link)
    select c.owner_id,'Job expiring soon', j.title||' closes on '||j.deadline,'company.html'
    from jobs j join companies c on c.id=j.company_id
    where j.status='published' and j.deadline = current_date + 3;
  update jobs set status='expired' where status='published' and deadline < current_date;
end $$;
revoke all on function expire_jobs() from public, anon, authenticated;

-- ───────────── Row Level Security ─────────────
alter table profiles enable row level security;
alter table companies enable row level security;
alter table jobs enable row level security;
alter table job_applications enable row level security;
alter table loan_applications enable row level security;
alter table loan_repayments enable row level security;
alter table posts enable row level security;
alter table threads enable row level security;
alter table thread_messages enable row level security;
alter table support_requests enable row level security;
alter table notifications enable row level security;
alter table activity_log enable row level security;

-- profiles
create policy "own profile read" on profiles for select using (id = auth.uid() or is_admin());
create policy "own profile update" on profiles for update using (id = auth.uid() or is_admin());
-- company owners can read applicant profiles only for applications to their jobs
create policy "company reads applicant profile" on profiles for select using (
  exists (select 1 from job_applications a join jobs j on j.id=a.job_id join companies c on c.id=j.company_id
          where a.student_id = profiles.id and c.owner_id = auth.uid()));

-- companies
create policy "public approved companies" on companies for select using (status = 'approved' or owner_id = auth.uid() or is_admin());
create policy "company insert own" on companies for insert with check (owner_id = auth.uid());
create policy "company update own" on companies for update using (owner_id = auth.uid() or is_admin());

-- jobs
create policy "jobs read" on jobs for select using (
  (status = 'published' and deadline >= current_date)
  or exists (select 1 from companies c where c.id = company_id and c.owner_id = auth.uid())
  or is_admin());
create policy "jobs insert" on jobs for insert with check (
  exists (select 1 from companies c where c.id = company_id and c.owner_id = auth.uid()) or is_admin());
create policy "jobs update" on jobs for update using (
  exists (select 1 from companies c where c.id = company_id and c.owner_id = auth.uid()) or is_admin());
create policy "jobs delete" on jobs for delete using (
  exists (select 1 from companies c where c.id = company_id and c.owner_id = auth.uid()) or is_admin());

-- job applications
create policy "app read" on job_applications for select using (
  student_id = auth.uid() or is_admin()
  or exists (select 1 from jobs j join companies c on c.id=j.company_id where j.id = job_id and c.owner_id = auth.uid()));
create policy "app insert" on job_applications for insert with check (
  student_id = auth.uid()
  and exists (select 1 from profiles p where p.id = auth.uid() and p.role='student' and not p.suspended)
  and exists (select 1 from jobs j where j.id = job_id and j.status='published' and j.deadline >= current_date));
create policy "app update by company/admin" on job_applications for update using (
  is_admin() or exists (select 1 from jobs j join companies c on c.id=j.company_id where j.id = job_id and c.owner_id = auth.uid()));

-- loans: student sees own; officers see all; student insert-only
create policy "loan read" on loan_applications for select using (student_id = auth.uid() or is_loan_officer());
create policy "loan insert" on loan_applications for insert with check (
  student_id = auth.uid() and exists (select 1 from profiles p where p.id=auth.uid() and p.role='student' and not p.suspended));
create policy "loan update officers" on loan_applications for update using (is_loan_officer());
create policy "repay read" on loan_repayments for select using (
  is_loan_officer() or exists (select 1 from loan_applications l where l.id = loan_id and l.student_id = auth.uid()));
create policy "repay write" on loan_repayments for insert with check (is_loan_officer());

-- posts: everyone signed-in or anonymous may read; only admins write
create policy "posts read" on posts for select using (true);
create policy "posts admin write" on posts for insert with check (is_admin());
create policy "posts admin update" on posts for update using (is_admin());
create policy "posts admin delete" on posts for delete using (is_admin());

-- threads
create policy "thread read" on threads for select using (owner_id = auth.uid() or is_admin());
create policy "thread insert" on threads for insert with check (owner_id = auth.uid());
create policy "thread update admin" on threads for update using (is_admin());
create policy "msg read" on thread_messages for select using (
  is_admin() or exists (select 1 from threads t where t.id = thread_id and t.owner_id = auth.uid()));
create policy "msg insert" on thread_messages for insert with check (
  sender_id = auth.uid() and (is_admin() or exists (select 1 from threads t where t.id = thread_id and t.owner_id = auth.uid())));

-- support (anyone may submit; only admins read)
create policy "support submit" on support_requests for insert with check (user_id is null or user_id = auth.uid());
create policy "support admin read" on support_requests for select using (is_admin());
create policy "support admin update" on support_requests for update using (is_admin());

-- notifications
create policy "notif own read" on notifications for select using (user_id = auth.uid());
create policy "notif own update" on notifications for update using (user_id = auth.uid());
create policy "activity admin" on activity_log for select using (is_admin());

-- ───────────── Storage ─────────────
-- PRIVATE: identity docs & company verification docs. PUBLIC: post attachments, company logos.
insert into storage.buckets (id, name, public) values
  ('identity-docs','identity-docs',false),
  ('company-docs','company-docs',false),
  ('company-logos','company-logos',true),
  ('post-media','post-media',true)
on conflict (id) do nothing;

-- identity-docs: path must start with the uploader's user id; student uploads, only loan officers read (plus the owner)
create policy "identity upload own" on storage.objects for insert to authenticated
  with check (bucket_id='identity-docs' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "identity read" on storage.objects for select to authenticated
  using (bucket_id='identity-docs' and ((storage.foldername(name))[1] = auth.uid()::text or is_loan_officer()));

create policy "cdocs upload own" on storage.objects for insert to authenticated
  with check (bucket_id='company-docs' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "cdocs read" on storage.objects for select to authenticated
  using (bucket_id='company-docs' and ((storage.foldername(name))[1] = auth.uid()::text or is_admin()));

create policy "logos upload own" on storage.objects for insert to authenticated
  with check (bucket_id='company-logos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "logos public read" on storage.objects for select using (bucket_id='company-logos');

create policy "post media admin upload" on storage.objects for insert to authenticated with check (bucket_id='post-media' and is_admin());
create policy "post media public read" on storage.objects for select using (bucket_id='post-media');

-- ───────────── Creating the FIRST administrator ─────────────
-- 1. Register normally on the site with the admin's email.
-- 2. Then run once in the SQL editor:
--    update profiles set role = 'admin' where email = 'YOUR_ADMIN_EMAIL';

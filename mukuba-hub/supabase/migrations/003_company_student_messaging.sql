-- 003: in-platform messaging between a company and students who applied to its jobs.
-- Threads with recipient_id NULL are addressed to administrators (private admin inbox).
-- Threads with recipient_id set are company<->student; admins cannot read those.
alter table threads add column if not exists recipient_id uuid references profiles(id) on delete cascade;

create or replace function is_thread_participant(tid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from threads t where t.id = tid and (
    t.owner_id = auth.uid() or t.recipient_id = auth.uid() or (t.recipient_id is null and is_admin())));
$$;

drop policy if exists "thread read" on threads;
drop policy if exists "thread insert" on threads;
drop policy if exists "thread update admin" on threads;
create policy "thread read" on threads for select using (
  owner_id = auth.uid() or recipient_id = auth.uid() or (recipient_id is null and is_admin()));
create policy "thread insert" on threads for insert with check (
  owner_id = auth.uid() and (
    recipient_id is null
    or exists (select 1 from job_applications a join jobs j on j.id = a.job_id join companies c on c.id = j.company_id
               where a.student_id = recipient_id and c.owner_id = auth.uid())));
create policy "thread update" on threads for update using (
  (recipient_id is null and is_admin()) or owner_id = auth.uid());

drop policy if exists "msg read" on thread_messages;
drop policy if exists "msg insert" on thread_messages;
create policy "msg read" on thread_messages for select using (is_thread_participant(thread_id));
create policy "msg insert" on thread_messages for insert with check (sender_id = auth.uid() and is_thread_participant(thread_id));

create or replace function trg_thread_events() returns trigger language plpgsql security definer set search_path = public as $$
declare t threads;
begin
  select * into t from threads where id = new.thread_id;
  update threads set last_message_at = now() where id = t.id;
  if t.recipient_id is not null then
    perform notify(case when new.sender_id = t.owner_id then t.recipient_id else t.owner_id end,
      'New message: '||t.subject, left(new.body,120),'messages.html');
  elsif new.sender_id = t.owner_id then
    update threads set resolved = false where id = t.id;
    perform notify_admins('New message: '||t.subject, left(new.body,120),'admin.html#messages');
  else
    perform notify(t.owner_id,'Reply from administration', left(new.body,120),'messages.html');
  end if;
  return new;
end $$;

drop function if exists company_applicants();
create or replace function company_applicants()
returns table (application_id uuid, student_id uuid, job_id uuid, job_title text, status app_status, company_note text, cover_note text,
               applied_at timestamptz, full_name text, email text, phone text, school text, programme text,
               year_of_study int, availability jsonb)
language sql stable security definer set search_path = public as $$
  select a.id, p.id, j.id, j.title, a.status, a.company_note, a.cover_note, a.created_at,
         p.full_name, p.email, p.phone, p.school, p.programme, p.year_of_study, p.availability
  from job_applications a join jobs j on j.id = a.job_id join companies c on c.id = j.company_id
  join profiles p on p.id = a.student_id
  where c.owner_id = auth.uid() order by a.created_at desc;
$$;
revoke all on function company_applicants() from public, anon;
grant execute on function company_applicants() to authenticated;

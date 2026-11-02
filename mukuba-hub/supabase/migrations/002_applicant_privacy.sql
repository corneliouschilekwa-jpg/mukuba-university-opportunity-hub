-- 002: tighten what employers can see about applicants.
-- RLS cannot restrict columns, so remove the broad policy and expose a limited function instead.
drop policy if exists "company reads applicant profile" on profiles;

create or replace function company_applicants()
returns table (application_id uuid, job_id uuid, job_title text, status app_status, company_note text, cover_note text,
               applied_at timestamptz, full_name text, email text, phone text, school text, programme text,
               year_of_study int, availability jsonb)
language sql stable security definer set search_path = public as $$
  select a.id, j.id, j.title, a.status, a.company_note, a.cover_note, a.created_at,
         p.full_name, p.email, p.phone, p.school, p.programme, p.year_of_study, p.availability
  from job_applications a
  join jobs j on j.id = a.job_id
  join companies c on c.id = j.company_id
  join profiles p on p.id = a.student_id
  where c.owner_id = auth.uid()
  order by a.created_at desc;
$$;
revoke all on function company_applicants() from public, anon;
grant execute on function company_applicants() to authenticated;
-- NRC and student number are deliberately NOT returned to employers.

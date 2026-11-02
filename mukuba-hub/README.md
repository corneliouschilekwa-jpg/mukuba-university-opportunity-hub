# Mukuba University Student Opportunity Hub

Static frontend (`web/`) + Supabase backend (`supabase/`). No build step. No demo data: the database starts empty.

## Honest status

Written and syntax-checked, **but not run against a live Supabase project** (no Supabase credentials or Postgres server were available where this was built). The SQL and every user journey below must be tested by you before launch. Expect to fix small bugs on first run.

## Setup (about 20 minutes)

1. **Create a Supabase project** at supabase.com (choose a region close to Zambia, e.g. EU/South Africa if offered).
2. **Run the database**: SQL Editor → paste `supabase/migrations/001_schema.sql` → Run. Then run `002_applicant_privacy.sql`, then `003_company_student_messaging.sql`. If 001 reports an error, fix it before continuing; do not skip.
3. **Connect the frontend**: Project Settings → API. Copy *Project URL* and the *anon public* key into `web/config.js`. Never use the `service_role` key anywhere in `web/`.
4. **Auth settings** (Authentication → Providers → Email): keep "Confirm email" ON. Under URL Configuration set Site URL to your deployed address and add `…/login.html` and `…/reset.html` to Redirect URLs.
5. **Email delivery**: Supabase's built-in mailer is heavily rate-limited. For real use, configure SMTP (Authentication → SMTP) with a provider such as Resend, Brevo or Zoho.
6. **Create the first administrator**: register normally on the site, confirm the email, then in SQL Editor run
   `update profiles set role = 'admin' where email = 'you@example.com';`
   To add a loan-only reviewer use `role = 'loan_officer'`. Only these people can open NRC/selfie images.
7. **Storage** buckets are created by the SQL: `identity-docs` and `company-docs` (private), `company-logos` and `post-media` (public: only logos and announcement media).
8. **Expiring jobs**: enable the `pg_cron` extension, then run
   `select cron.schedule('expire-jobs','0 1 * * *','select expire_jobs()');`
   This marks past-deadline jobs expired and warns companies 3 days ahead.
9. **Deploy** the `web/` folder to any static host (Netlify, Cloudflare Pages, Vercel, GitHub Pages) with HTTPS. Camera capture only works over HTTPS.
10. **Backups**: Supabase Pro includes daily backups and point-in-time recovery. On the free plan, schedule `pg_dump` yourself (Database → Backups) and test a restore.

## What is implemented

- Student / company / admin accounts, email verification, password reset, suspension.
- Companies: profile + logo + verification documents; admin approval required before posting; jobs need admin approval to go live; edit, close, delete; applicants list with status updates.
- Jobs: search, location/type/weekend filters, and "Find Jobs That Fit My Timetable" (a job matches only if all its days are within your free days and its hours inside your window).
- Six-step loan wizard with progress bar, consent gate, file upload or live camera capture with preview/retake, declaration, reference number (`MUK-LN-YYYY-####`), student tracking.
- Admin: stats from real counts, companies, jobs, loans (search, secure document viewing via 5-minute signed links, request info, approve with amount and terms, reject with reason, repayments, CSV export), announcements with image/PDF, inbox with replies and resolve, support inbox, account suspension, activity log.
- Company ↔ applicant messaging inside the platform (admins cannot read these; the admin inbox holds only messages addressed to administrators).
- In-app notifications (database triggers) with bell, read/unread.
- Privacy Policy and Terms (drafts).

## Security design

- Row Level Security on every table; students see only their own loans/documents; employers see only applicants to their own jobs and **not** NRC or student number (`company_applicants()` function).
- Users cannot change their own role, company status, job status or loan status (guard triggers).
- Identity documents are in a private bucket and are read through short-lived signed URLs, only by admins/loan officers (or the owner).
- Only the public anon key is in the frontend.

## Known gaps — decide before launch

- **Legal**: privacy/terms are drafts. Have the university legal office and data controller review them against Zambia's Data Protection Act, 2021 (including registration with the Data Protection Commission and retention periods).
- **Not tested** with real Supabase, real devices, or multiple concurrent users. Test on actual phones, including the camera flow.
- Notifications are in-app only; there are no email/SMS alerts for status changes.
- File type is checked by the browser only; add Supabase storage bucket MIME/size limits (Storage → bucket settings) as a second layer.
- No rate limiting or CAPTCHA on registration/support form; enable Supabase CAPTCHA (Auth → Bot protection) before public launch.
- "Approve" records an approved amount and terms; actual disbursement and repayment collection happen outside the platform.
- Student number is not validated against a university register, so anyone can claim a number. For real identity assurance, have admins check the uploaded documents (the selfie comparison is manual) or get a student register export.
- Suspended users stay logged in until their session expires, though the pages and RLS check the flag.

## Test checklist

1. Register a student → verify email → log in → dashboard loads.
2. Register a company → log in → submit profile + document → log in as admin → approve.
3. Company posts job → admin publishes → job appears on Jobs, student gets notification → student applies → company sees applicant and shortlists → student sees status.
4. Student submits a loan with all five images → admin opens it, views documents, requests info, approves, records repayment → student sees each update.
5. Confirm a second student **cannot** see the first student's loan or files (try opening a signed URL path, and querying `loan_applications` from the browser console).
6. Admin publishes an announcement with a PDF; it appears on News and notifies users when marked important.
7. Help-centre form → appears in Admin → Support.
8. Password reset email → new password works.

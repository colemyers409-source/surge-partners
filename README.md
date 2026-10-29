# Surge Recruit

Surge-owned recruiting platform (SalesDraft-style): applicant pipeline, SMS threads, interview/NHO scheduling, candidate self-booking portal, openings, affiliate links, recruiter scoreboard.

## Files
- `index.html` — recruiter app (sign-in required). Add `?demo=1` to preview with sample data.
- `c.html` — candidate portal. Served at `/c/<token>` (Netlify redirect in `netlify.toml` / `_redirects`).
- `apply.html` — public application form. `?ref=NAME` credits a recruiter, `?pos=<id>` preselects an opening.
- `schema.sql` — Supabase tables, RLS, RPCs, triggers. Run once in the SQL editor; safe to re-run.
- `config.js` — Supabase URL + anon key (public), status list.

## Go live (10 minutes)
1. Supabase → SQL editor → paste `schema.sql` → Run.
2. Supabase → Authentication → Providers → Email → turn off "Confirm email" (optional, for instant recruiter sign-ins).
3. Netlify → drag this folder (or the zip) onto Drop. Set a custom domain if you want (e.g. recruit.surgepartners.com).
4. Open the site, "Create account" — the first account becomes admin. Joey creates his the same way.
5. Calendar → Add slots (e.g. Mon–Fri 7:00 PM, capacity 50, 2 weeks, your Zoom link).
6. Point ads at `https://<site>/apply.html?ref=cole` etc. Affiliate Links page generates them.

Applicants from the old recruiting site (`recruits` table) are mirrored into the pipeline automatically.

## Phase 2 (texting + AI) — hooks already in place
- Outbound: every message goes to `rp_outbox` (status `pending`). Edge Function on a cron sends via Twilio and marks `sent`.
- Inbound: Twilio webhook → Edge Function → `select rp_inbound_sms(from, body)`. STOP flags DNC automatically.
- AI replies + resume scoring: Edge Function calling Claude; writes `ai_score / ai_strengths / ai_concerns` and posts replies as sender `ai`.
- Reminders / no-show nudges: cron using the `rp_templates` bodies.

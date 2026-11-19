# SharpVE Gurukull — Digital CBT & Diagnostic Portal (v4.0)

## Files Included
1. `admin.html` — Teacher Portal (PIN protected, default PIN: `2026`). Includes AI test generator, mandatory **Review & Edit** before publish, 6-digit Test Code generator, Question/Option Shuffle, Negative Marking toggle, Student Roster (Roll No + PIN + Last Year %), Offline WTP/School marks, Class Weak-Topic Heatmap, WhatsApp Parent Report, and CSV/JSON export.
2. `student.html` — Student Exam & Diagnostic Portal (opens with Test Code + Roll No + PIN, strips answer keys before submission, saves draft on refresh so timer/answers aren't lost, and shows instant weak/strong topic & variety diagnosis).
3. `supabase_schema.sql` — Ready-to-run PostgreSQL schema & server-side RPCs (`cbt_start_or_resume_attempt`, `cbt_save_draft`, `cbt_submit_attempt`) for multi-device cloud sync on Supabase.

## How to Run Tomorrow
- **Quick Start (Today/Tomorrow):** Open `admin.html` and `student.html` in your browser (or deploy both files together to GitHub Pages / Netlify).
- **Cloud Sync (Optional):** Run `supabase_schema.sql` in your Supabase SQL Editor and paste your Project URL + Anon Key under **Optional: Connect Supabase Cloud** in `admin.html`.

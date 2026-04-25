# AmmaKatha — Complete Setup Guide
## From Zero to Live in ~60 minutes

---

## FILES DELIVERED

| File | Purpose |
|------|---------|
| `login.html` | Phone + 6-digit PIN login, 6-language UI |
| `app.html` | Main app — home, player, voice record, AI story, subscribe, profile |
| `admin.html` | Admin panel — users, payments, QR codes, stories, config |
| `schema.sql` | Full Supabase DB schema (partitioned for 1M+ users) |
| `supabase/functions/verify-pin/index.ts` | Edge Function: secure PIN verification |
| `supabase/functions/create-user/index.ts` | Edge Function: admin user creation with bcrypt |

---

## STEP 1 — Create Supabase Project

1. Go to https://supabase.com → New Project
2. Pick region: **ap-south-1** (Mumbai) — lowest latency for India
3. Set a strong DB password — save it
4. Wait ~2 minutes for provisioning

---

## STEP 2 — Run the Database Schema

1. In Supabase → **SQL Editor** → New Query
2. Paste entire contents of `schema.sql`
3. Click **Run**
4. Verify tables created: `users`, `stories`, `payments`, `payment_qr_codes`, etc.

---

## STEP 3 — Create Storage Buckets

In Supabase → **Storage** → New Bucket:

| Bucket Name | Public? | Purpose |
|-------------|---------|---------|
| `voice-samples` | ❌ Private | Mother's voice recordings |
| `story-audio` | ✅ Public | Story audio files (CDN) |
| `story-thumbnails` | ✅ Public | Story cover images |
| `payment-qr` | ✅ Public | QR code images shown to users |
| `payment-screenshots` | ❌ Private | User payment proof uploads |
| `generated-audio` | ❌ Private | AI-generated story audio |

---

## STEP 4 — Deploy Edge Functions

Install Supabase CLI first:
```bash
npm install -g supabase
supabase login
supabase link --project-ref YOUR_PROJECT_REF
```

Deploy both functions:
```bash
supabase functions deploy verify-pin
supabase functions deploy create-user
```

Set secrets:
```bash
supabase secrets set SUPABASE_SERVICE_ROLE_KEY=your_service_role_key
```

---

## STEP 5 — Configure the HTML Files

In **all 3 HTML files** (login.html, app.html, admin.html), replace:

```javascript
const SUPABASE_URL = 'https://YOUR_PROJECT.supabase.co';
const SUPABASE_ANON_KEY = 'YOUR_ANON_KEY';
```

Find these values in: Supabase → Settings → API

---

## STEP 6 — Set Up Admin Login

Supabase handles admin auth via its built-in Auth system:

1. Supabase → **Authentication** → Users → Invite User
2. Enter your email → Send invite
3. Check email → set password
4. In SQL Editor, add your email to the admins table:
```sql
INSERT INTO admins (email, name, role) 
VALUES ('your@email.com', 'Your Name', 'super');
```
5. Create `admin-login.html` (simple Supabase email/password login page)

---

## STEP 7 — App Config Values

In admin panel → App Config, set:

| Key | Value |
|-----|-------|
| `claude_api_key` | Your Anthropic API key |
| `elevenlabs_api_key` | Your ElevenLabs API key |
| `support_whatsapp` | `919XXXXXXXXX` (no + sign) |
| `free_stories_per_day` | `3` |
| `trial_days` | `7` |

---

## STEP 8 — Upload First QR Code

1. Open `admin.html`
2. Go to **QR Codes** → Add QR Code
3. Upload your PhonePe/GPay/Paytm QR image
4. Enter your UPI ID
5. Click Upload — it auto-activates

Users will now see this QR when they go to Subscribe.

---

## STEP 9 — Create First User

1. Admin panel → **Create User**
2. Fill: Mother name, Child name, Phone (+91XXXXXXXXXX), 6-digit PIN
3. Select language, plan if paid
4. Click Create User

User can now login at `login.html` with their phone + PIN.

---

## STEP 10 — Add Stories

1. Admin panel → **Add Story**
2. Paste story text in regional language (Telugu/Tamil etc.)
3. Set category, age range, emoji
4. Check "Published"
5. Click Add Story

For audio: upload `.mp3` to `story-audio` bucket, paste URL in Audio URL field.

---

## SCALE NOTES (for 1M users)

### Database
- All high-write tables are **range-partitioned** by time
- Indexes on phone, subscription_status, lang_code, played_at
- Use **PgBouncer transaction mode** (Supabase default) — handles 10K+ concurrent connections
- Add **read replicas** for analytics queries (Supabase Pro+)
- Enable **PITR** (Point-in-Time Recovery) backups

### Performance
- **Materialized view** `user_streaks` — refresh nightly via pg_cron
- Story audio served from Supabase CDN (public bucket = automatic CDN)
- Add `supabase/functions/clean-sessions` cron to delete expired sessions weekly

### Security
- PINs stored as **bcrypt hash** (cost 12) — never plaintext
- Edge Functions use **SERVICE_ROLE_KEY** server-side only
- RLS enabled on all user tables
- Session tokens hashed before storage

### Monitoring
- Enable `pg_stat_statements` extension (already in schema)
- Set up Supabase alerts for DB size, connection count
- Monitor Edge Function invocations in Supabase dashboard

---

## PAYMENT FLOW (No UPI SDK)

```
User selects plan
       ↓
App loads QR from payment_qr_codes table
       ↓
User opens PhonePe/GPay and scans QR
       ↓
User pays and takes screenshot
       ↓
User uploads screenshot in app
       ↓
Payment saved to DB with status: screenshot_uploaded
       ↓
Admin sees it in Payments panel → clicks Verify
       ↓
User subscription activated automatically
```

---

## VOICE CLONING FLOW (ElevenLabs)

```
User records 30s audio in app
       ↓
Audio blob uploaded to voice-samples bucket
       ↓
Call ElevenLabs /v1/voices/add API with audio file
       ↓
ElevenLabs returns voice_id
       ↓
voice_id saved to users.elevenlabs_voice_id
       ↓
For TTS: POST /v1/text-to-speech/{voice_id}
       ↓
Audio saved to generated-audio bucket
```

ElevenLabs API endpoint:
```
POST https://api.elevenlabs.io/v1/voices/add
Headers: xi-api-key: YOUR_KEY
Body (multipart): name=amma_userId, files=audioBlob
```

---

## NEXT BUILDS

- [ ] `admin-login.html` — Email/password for admins
- [ ] ElevenLabs clone-voice Edge Function  
- [ ] TTS generation Edge Function
- [ ] Offline service worker (story download)
- [ ] Push notifications (10pm reminder via Firebase)
- [ ] Flutter Android APK wrapper

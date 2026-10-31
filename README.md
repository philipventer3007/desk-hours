# 📚 Desk Hours

A tiny, free study-time leaderboard for a group of friends. Log time with a timer or by hand, and compete on Today / This Week / All Time leaderboards.

- **Frontend:** one `index.html` (plain JS + Tailwind CDN + supabase-js CDN). No build step, no npm.
- **Backend:** Supabase free tier (Postgres + Auth + Row Level Security).
- **Hosting:** Netlify Drop or GitHub Pages (both free).

```
index.html            the whole app
Ranks/                tier logos and backgrounds
supabase/schema.sql   tables, security policies, leaderboard SQL
README.md             this file
```

## Setup

1. **Create a free Supabase project**
   1. Go to <https://supabase.com> and sign up (free).
   2. Click **New project**, pick the **Free** plan, give it a name (e.g. `desk-hours`), set a database password (save it somewhere), and choose a nearby region (e.g. *Africa (Cape Town)* if offered, otherwise *West EU*).
   3. Wait a minute or two until the project finishes setting up.

2. **Turn OFF email confirmation** so friends can log in straight after signing up
   1. In the Supabase dashboard go to **Authentication → Providers → Email** (in newer dashboards: **Authentication → Sign In / Providers → Email**).
   2. Switch **Confirm email** OFF and click **Save**.

3. **Run the schema**
   1. Open **SQL Editor → New query**.
   2. Paste the entire contents of `supabase/schema.sql` and click **Run**.
   3. You should see "Success. No rows returned". It's safe to run again any time, for example after pulling an update.

4. **Paste your URL and anon key into `index.html`**
   1. In Supabase go to **Project Settings → API** (or **Project Settings → Data API / API Keys**).
   2. Copy the **Project URL** and the **anon / public** key.
   3. Open `index.html` in a text editor. At the top of the `<script>` block, replace the placeholders:
      ```js
      const SUPABASE_URL = 'https://abcd1234.supabase.co';
      const SUPABASE_ANON_KEY = 'eyJhbGciOi...';
      ```
   4. The anon key is meant to be public, and Row Level Security protects the data. **Never** put the `service_role` key in this file.

5. **Try it locally:** double-click `index.html` to open it in your browser, sign up, and log a session.

6. **Deploy (pick one)**
   - **Netlify Drop:**
     1. Go to <https://app.netlify.com/drop> (a free Netlify account keeps the site permanently).
     2. Drag the whole `Desk Hours` project folder onto the page.
     3. Share the `https://….netlify.app` URL with your friends.
     4. To update the site later, drag the folder again from **Site → Deploys**.
   - **GitHub Pages:**
     1. Create a new GitHub repository and upload `index.html` and the `Ranks` folder (and the `supabase` folder if you like).
     2. In the repo go to **Settings → Pages**. Under *Build and deployment* choose **Deploy from a branch**, select `main` and `/ (root)`, then click **Save**.
     3. After about a minute your site is live at `https://<your-username>.github.io/<repo-name>/`.

7. **(Recommended) Close sign-ups once everyone has joined.** There is no invite code, so anyone who finds the URL can create an account and appear on the leaderboard. When all your friends have signed up, go to **Authentication → Sign In / Providers** and switch **Allow new users to sign up** OFF. Switch it back on temporarily if someone new wants to join.

## How it works

- **Sign-up:** the display name is sent as user metadata. A database trigger (`handle_new_user`) creates the matching row in `profiles`.
- **Security (RLS on every table):**
  - Every signed-in user with a profile can read all profiles and all sessions.
  - Users can only insert, edit or delete **their own** sessions (`sessions_insert_own`, `sessions_update_own`, `sessions_delete_own`, all checking `user_id = auth.uid()`).
  - Users can only rename themselves (`profiles_update_own`, and only the `display_name` column is updatable).
- **Time zone:** "today" and "this week" (starting Monday) are calculated in SQL in `Africa/Johannesburg` time.
- **Timer:** the start time is stored in your browser's `localStorage`, so refreshing or closing the tab doesn't lose it. The timer only runs in the browser you started it in. Use **Pause/Resume** for breaks; paused time isn't counted, and a paused timer stays paused through a refresh. While paused you can also **Discard** the session to throw it away without saving. Runs shorter than 5 minutes are discarded, and the app tells you so.
- **Live on the leaderboard:** while your timer runs, a flickering red light shows next to your name and your time ticks up every second for everyone (paused timers keep their time but lose the light). Starting, pausing, resuming and stopping are shared through the `live_timers` table, so friends see changes within 30 seconds (the leaderboard refresh).
- **Forgotten timers:** if a timer runs 6 hours without a pause, it is paused automatically at the 6-hour mark (even if the tab is closed; the database works it out). That person is greyed out and moved to the bottom of the leaderboard until they resume or stop the timer. The limit is `FORGOTTEN_MS` in `index.html` and `6 * 3600 * 1000` in `schema.sql`; change both together.
- **Tiers:** each full hour moves you up a tier: under 1 h is plain, then 1 h Silver, 2 h Diamond, 3 h Platinum, 4 h Gold, 5 h Elite, 6 h Champion, 7 h+ Unreal (live timer included). On **Today** the tier uses your time today. On **This week** it uses your average per day: the larger of (time before today ÷ full days already over this week) and (whole week's time ÷ those days + today). Today only counts as a day once it raises your average, so the tier is never dragged down by hours that haven't happened yet and never inflated by dividing by part of a day; by midnight both give the same answer. On Monday it's simply today's time. **All time** has no tiers. Your spot shows the tier's background with a matching border, and its logo sits next to your name (hover it on This week to see the average). The images come from the `Ranks` folder (`*_logo.png` and the smaller `*_background_web.jpg` copies); edit `TIERS` in `index.html` to change names, colours or order.
- **Everyone is listed:** every member shows on every leaderboard tab, with 0m if they haven't studied in that period.
- **Ties:** people with equal time are ordered by their total this week, then by their all-time total (live timers included). They only share a rank if all three are equal.
- **Messages:** type a message (up to 80 characters) above the leaderboard and press **Post**. It shows under your name for everyone. Posting again replaces it and restarts its hour, it disappears by itself an hour after posting, and **Remove** takes it down early. Messages live in the `board_messages` table; the 1-hour limit is `interval '1 hour'` in the `leaderboard` function in `schema.sql`.
- **Calendar:** My stats shows one month at a time. Each day gets a brighter green the more you studied that day (1–29 min, 30–59 min, 1–2 h, 2–4 h, 4 h+). Use ‹ › to switch months.
- **Display name:** change it any time under **My stats → Display name**.
- **Admin:** admins get an **Admin** tab listing every member with their email and all-time total. From there they can **Disable** a member: they can still see everything, but can't log or edit time, run a timer, post messages or rename themselves, and their live timer and message are taken down. On the leaderboard they're greyed out with a red **Cheater** badge and no rank, placed below everyone with time and above people on 0 or **Enable** them again, and **Reset times**: delete that member's saved sessions for Today, This week or All time. A timer still running in the member's browser isn't affected by a reset. Admins are set by email in the *Admin* section of `schema.sql` (`is_admin` on `profiles`, which users can't change themselves); the person must have signed up before you run the schema, so re-run it after a new admin joins. Every admin action is checked in the database (`admin_list_users`, `admin_set_disabled`, `admin_reset_times`), not just hidden in the page.

## Free-tier notes

- Supabase pauses free projects after about a week with no activity. If that happens, open the dashboard and click **Restore**.
- The Tailwind CDN prints a "not for production" warning in the browser console. For a small friends-only site it's fine to ignore.

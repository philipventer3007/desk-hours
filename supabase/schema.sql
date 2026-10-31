-- =====================================================================
-- Desk Hours schema. Paste into Supabase > SQL Editor and Run.
-- Idempotent: safe to run as many times as you like.
-- =====================================================================

-- ---------- Tables ----------------------------------------------------

create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 40),
  created_at   timestamptz not null default now()
);

create table if not exists public.study_sessions (
  id           bigint generated always as identity primary key,
  user_id      uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  subject      text not null check (char_length(btrim(subject)) between 1 and 60),
  minutes      int  not null check (minutes > 0),
  session_date date not null default (now() at time zone 'Africa/Johannesburg')::date,
  created_at   timestamptz not null default now()
);

create index if not exists study_sessions_user_date_idx on public.study_sessions (user_id, session_date);
create index if not exists study_sessions_date_idx      on public.study_sessions (session_date);

-- ---------- Helpers ---------------------------------------------------

-- "Today" in South African time.
create or replace function public.jhb_today()
returns date
language sql stable
set search_path = ''
as $$ select (now() at time zone 'Africa/Johannesburg')::date $$;

-- True if the caller has a profile. SECURITY DEFINER so policies on
-- profiles can use it without recursing into their own RLS.
create or replace function public.is_member()
returns boolean
language sql stable security definer
set search_path = ''
as $$ select exists (select 1 from public.profiles where id = auth.uid()) $$;

-- ---------- Auto-create a profile on sign-up --------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    left(coalesce(nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''),
                  nullif(split_part(new.email, '@', 1), ''),
                  'Student'), 40)
  )
  on conflict (id) do nothing;
  return new;
end
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Backfill profiles for any users created before this trigger existed.
insert into public.profiles (id, display_name)
select u.id,
       left(coalesce(nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
                     nullif(split_part(u.email, '@', 1), ''),
                     'Student'), 40)
from auth.users u
on conflict (id) do nothing;

-- ---------- Row Level Security ---------------------------------------

alter table public.profiles       enable row level security;
alter table public.study_sessions enable row level security;

-- Table privileges: anon gets nothing; signed-in users get only what the
-- policies below allow. Profiles are inserted only by the trigger, and
-- only display_name is updatable.
revoke all on public.profiles, public.study_sessions from anon;
revoke insert, update, delete on public.profiles from authenticated;
grant select on public.profiles to authenticated;
grant update (display_name) on public.profiles to authenticated;
grant select, insert, update, delete on public.study_sessions to authenticated;

-- profiles: every member can read all profiles
drop policy if exists profiles_select_members on public.profiles;
create policy profiles_select_members on public.profiles
  for select to authenticated
  using (public.is_member());

-- profiles: a user can rename only themselves
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- study_sessions: every member can read all sessions
drop policy if exists sessions_select_members on public.study_sessions;
create policy sessions_select_members on public.study_sessions
  for select to authenticated
  using (public.is_member());

-- study_sessions: insert only as yourself
drop policy if exists sessions_insert_own on public.study_sessions;
create policy sessions_insert_own on public.study_sessions
  for insert to authenticated
  with check (public.is_member() and user_id = auth.uid());

-- study_sessions: edit only your own rows (and can't hand them to someone else)
drop policy if exists sessions_update_own on public.study_sessions;
create policy sessions_update_own on public.study_sessions
  for update to authenticated
  using (public.is_member() and user_id = auth.uid())
  with check (public.is_member() and user_id = auth.uid());

-- study_sessions: delete only your own rows
drop policy if exists sessions_delete_own on public.study_sessions;
create policy sessions_delete_own on public.study_sessions
  for delete to authenticated
  using (public.is_member() and user_id = auth.uid());

-- ---------- Streaks (removed) ---------------------------------------
-- The leaderboard used to depend on this view, so drop that first.
drop function if exists public.leaderboard(text);
drop view if exists public.user_streaks;

-- ---------- Live timers ----------------------------------------------
-- One row per person whose timer is running or paused, so friends see it
-- on the leaderboard. base_ms is the time counted before the current run;
-- running_since is when the current run started (null while paused). Times
-- come from the database clock, so wrong device clocks don't matter.
-- A run that goes 6 hours without a pause counts as a forgotten timer: it
-- stops counting at the 6 h mark and shows as paused and greyed out.

-- An earlier version stored elapsed_ms/running/updated_at. Rebuild the table
-- if it has that shape; timers are shared again the next time the app opens.
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'live_timers' and column_name = 'elapsed_ms') then
    drop table public.live_timers;
  end if;
end
$$;
drop function if exists public.set_live_timer(bigint, boolean);

create table if not exists public.live_timers (
  user_id       uuid primary key default auth.uid() references public.profiles (id) on delete cascade,
  base_ms       bigint not null check (base_ms >= 0),
  running_since timestamptz,
  forgotten     boolean not null default false
);

alter table public.live_timers enable row level security;
revoke all on public.live_timers from anon;
grant select, insert, update, delete on public.live_timers to authenticated;

-- live_timers: every member can see who is studying
drop policy if exists live_select_members on public.live_timers;
create policy live_select_members on public.live_timers
  for select to authenticated
  using (public.is_member());

-- live_timers: only your own timer can be created, changed or removed
drop policy if exists live_insert_own on public.live_timers;
create policy live_insert_own on public.live_timers
  for insert to authenticated
  with check (public.is_member() and user_id = auth.uid());

drop policy if exists live_update_own on public.live_timers;
create policy live_update_own on public.live_timers
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists live_delete_own on public.live_timers;
create policy live_delete_own on public.live_timers
  for delete to authenticated
  using (user_id = auth.uid());

-- Start, pause, resume or auto-pause: store the caller's timer.
-- elapsed_ms = total counted so far; run_ms = length of the current run
-- (0 when paused).
create or replace function public.set_live_timer(elapsed_ms bigint, run_ms bigint, running boolean, forgotten boolean)
returns void
language sql volatile security invoker
set search_path = ''
as $$
  insert into public.live_timers (user_id, base_ms, running_since, forgotten)
  values (auth.uid(),
          greatest(set_live_timer.elapsed_ms - case when set_live_timer.running then set_live_timer.run_ms else 0 end, 0),
          case when set_live_timer.running then now() - set_live_timer.run_ms * interval '1 millisecond' end,
          set_live_timer.forgotten)
  on conflict (user_id) do update
    set base_ms = excluded.base_ms, running_since = excluded.running_since, forgotten = excluded.forgotten;
$$;

-- Stop or discard: remove the caller's timer.
create or replace function public.clear_live_timer()
returns void
language sql volatile security invoker
set search_path = ''
as $$ delete from public.live_timers where user_id = auth.uid() $$;

-- ---------- Leaderboard messages -------------------------------------
-- One short message per person, shown under their name on the leaderboard.
-- Posting again replaces it; it stops showing an hour after it was posted.

create table if not exists public.board_messages (
  user_id   uuid primary key default auth.uid() references public.profiles (id) on delete cascade,
  body      text not null check (char_length(btrim(body)) between 1 and 80),
  posted_at timestamptz not null default now()
);

alter table public.board_messages enable row level security;
revoke all on public.board_messages from anon;
grant select, insert, update, delete on public.board_messages to authenticated;

-- board_messages: every member can read them
drop policy if exists msg_select_members on public.board_messages;
create policy msg_select_members on public.board_messages
  for select to authenticated
  using (public.is_member());

-- board_messages: only your own message can be created, changed or removed
drop policy if exists msg_insert_own on public.board_messages;
create policy msg_insert_own on public.board_messages
  for insert to authenticated
  with check (public.is_member() and user_id = auth.uid());

drop policy if exists msg_update_own on public.board_messages;
create policy msg_update_own on public.board_messages
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists msg_delete_own on public.board_messages;
create policy msg_delete_own on public.board_messages
  for delete to authenticated
  using (user_id = auth.uid());

-- Post (or replace) the caller's message; the hour starts again.
create or replace function public.set_board_message(body text)
returns void
language sql volatile security invoker
set search_path = ''
as $$
  insert into public.board_messages (user_id, body, posted_at)
  values (auth.uid(), btrim(set_board_message.body), now())
  on conflict (user_id) do update
    set body = excluded.body, posted_at = excluded.posted_at;
$$;

-- Remove the caller's message.
create or replace function public.clear_board_message()
returns void
language sql volatile security invoker
set search_path = ''
as $$ delete from public.board_messages where user_id = auth.uid() $$;

-- ---------- Leaderboard ----------------------------------------------
-- period: 'today' | 'week' (Monday start) | 'all'. Africa/Johannesburg time.
-- Lists every member, even with no time. Also returns each person's live
-- timer (if any) so the page can add it to their total and rank everyone
-- itself; run_left_ms is how long the current run has until it counts as
-- forgotten. today_minutes is the part of total_minutes logged today (the
-- page needs it for the weekly average tier). week_minutes and all_minutes
-- break ties on equal time. message is the person's leaderboard message if
-- it's under an hour old; message_left_ms is how long until it expires.

-- The return columns change between versions, so recreate it from scratch.
drop function if exists public.leaderboard(text);

create function public.leaderboard(period text)
returns table (user_id uuid, display_name text, total_minutes bigint, today_minutes bigint,
               week_minutes bigint, all_minutes bigint,
               live_ms bigint, live_running boolean, run_left_ms bigint, forgotten boolean,
               message text, message_left_ms bigint)
language sql stable security invoker
set search_path = ''
as $$
  with totals as (
    select s.user_id,
           sum(s.minutes) filter (where case period
             when 'today' then s.session_date = public.jhb_today()
             when 'week'  then s.session_date between date_trunc('week', public.jhb_today())::date
                                                  and public.jhb_today()
             else true
           end)::bigint as total,
           sum(s.minutes) filter (where s.session_date = public.jhb_today())::bigint as today_total,
           sum(s.minutes) filter (where s.session_date between date_trunc('week', public.jhb_today())::date
                                                           and public.jhb_today())::bigint as week_total,
           sum(s.minutes)::bigint as all_total
    from public.study_sessions s
    group by s.user_id
  ),
  live as (
    select l.user_id, l.base_ms, l.running_since, l.forgotten,
           (extract(epoch from now() - l.running_since) * 1000)::bigint as run_ms,
           6 * 3600 * 1000::bigint as limit_ms
    from public.live_timers l
  )
  select p.id, p.display_name, coalesce(t.total, 0), coalesce(t.today_total, 0),
         coalesce(t.week_total, 0), coalesce(t.all_total, 0),
         l.base_ms + case when l.running_since is null then 0 else least(l.run_ms, l.limit_ms) end,
         l.running_since is not null and l.run_ms < l.limit_ms,
         greatest(l.limit_ms - l.run_ms, 0),
         coalesce(l.forgotten or l.run_ms >= l.limit_ms, false),
         m.body,
         (extract(epoch from m.posted_at + interval '1 hour' - now()) * 1000)::bigint
  from public.profiles p
  left join totals t on t.user_id = p.id
  left join live l on l.user_id = p.id
  left join public.board_messages m on m.user_id = p.id and m.posted_at > now() - interval '1 hour'
  order by 3 desc, 2;
$$;

-- ---------- My stats -------------------------------------------------

-- Total minutes per subject (case-insensitive grouping).
create or replace function public.my_subject_totals()
returns table (subject text, total_minutes bigint)
language sql stable security invoker
set search_path = ''
as $$
  select min(btrim(s.subject)), sum(s.minutes)::bigint
  from public.study_sessions s
  where s.user_id = auth.uid()
  group by lower(btrim(s.subject))
  order by 2 desc;
$$;

-- Replaced by my_month_totals (calendar view).
drop function if exists public.my_daily_totals();

-- Daily totals for every day of the month containing month_start
-- (including zero days), oldest first. Used for the calendar heatmap.
create or replace function public.my_month_totals(month_start date)
returns table (day date, total_minutes bigint)
language sql stable security invoker
set search_path = ''
as $$
  with m as (
    select make_date(extract(year from month_start)::int, extract(month from month_start)::int, 1) as first
  ),
  days as (
    select (m.first + i) as day
    from m, generate_series(0, 30) as i
    where m.first + i < (m.first + interval '1 month')
  )
  select d.day, coalesce(sum(s.minutes), 0)::bigint
  from days d
  left join public.study_sessions s
         on s.user_id = auth.uid() and s.session_date = d.day
  group by d.day
  order by d.day;
$$;

-- ---------- Leaderboard reactions (removed) -------------------------
-- Drops the old reactions feature from databases that already have it.
drop function if exists public.toggle_reaction(uuid, text, text);
drop function if exists public.leaderboard_reactions(text);
drop table if exists public.reactions;
drop function if exists public.period_start(text);

revoke execute on function public.leaderboard(text)        from public, anon;
revoke execute on function public.my_subject_totals()      from public, anon;
revoke execute on function public.my_month_totals(date)    from public, anon;
grant  execute on function public.leaderboard(text)        to authenticated;
grant  execute on function public.my_subject_totals()      to authenticated;
grant  execute on function public.my_month_totals(date)    to authenticated;

revoke execute on function public.set_live_timer(bigint, bigint, boolean, boolean) from public, anon;
revoke execute on function public.clear_live_timer()              from public, anon;
grant  execute on function public.set_live_timer(bigint, bigint, boolean, boolean) to authenticated;
grant  execute on function public.clear_live_timer()              to authenticated;

revoke execute on function public.set_board_message(text) from public, anon;
revoke execute on function public.clear_board_message()    from public, anon;
grant  execute on function public.set_board_message(text) to authenticated;
grant  execute on function public.clear_board_message()    to authenticated;

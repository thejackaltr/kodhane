-- Shared-database checks (mode b): both v2.2 files applied to one database (today's supabase.teserix.com layout).
-- Run by run_v2_2_tests.sh after v2_2_kodhane.test.sql and v2_2_acik_ofis.test.sql.
\set ON_ERROR_STOP 1
\set u1 '11111111-1111-4111-8111-111111111111'
\set u2 '22222222-2222-4222-8222-222222222222'
set client_min_messages = notice;

select t.ok(not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname !~ '^(kodhane|acik_ofis)_')
        and not exists (select 1 from pg_class where relnamespace = 'public'::regnamespace and relname !~ '^(kodhane|acik_ofis)_'),
            'X1 every public table/index/function is game-prefixed (kodhane_* / acik_ofis_*): no shared object');
select t.ok(not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'acik_ofis%'
                          and pg_get_functiondef(p.oid) ~ 'public\.kodhane_'),
            'X2 no acik_ofis_* function references a kodhane_* object (the Açık Ofis file depends on no Kodhane object)');
select t.ok(not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'kodhane%'
                          and p.proname <> 'kodhane_leaderboard' and p.proname <> 'kodhane_count_event' and pg_get_functiondef(p.oid) ~ 'public\.acik_ofis_'),
            'X3 no kodhane_* function except kodhane_leaderboard (dynamic compat path) references acik_ofis_* objects');
select t.ok(not exists (select 1 from pg_trigger tg join pg_class c on c.oid = tg.tgrelid join pg_proc f on f.oid = tg.tgfoid
                         where not tg.tgisinternal and c.relnamespace = 'public'::regnamespace
                           and split_part(c.relname, '_', 1) <> split_part(f.proname, '_', 1)),
            'X4 every trigger uses its own game''s trigger function');

-- compatibility path vs Açık Ofis's own list: identical while the nickname mirror is fresh
select t.login(null);
create temp table x_lb_compat as select * from public.kodhane_leaderboard(50, 'acik_ofis');
create temp table x_lb_own as select * from public.acik_ofis_leaderboard(50);
select t.logout();
select t.ok((select count(*) from x_lb_compat) >= 2 and not exists (select * from x_lb_compat except select * from x_lb_own)
        and not exists (select * from x_lb_own except select * from x_lb_compat),
            'X5 kodhane_leaderboard(50, ''acik_ofis'') (compat, kodhane_profiles) = acik_ofis_leaderboard(50) (acik_ofis_profiles), anon');
select t.login(:'u2');
create temp table x_lb_compat2 as select * from public.kodhane_leaderboard(50, 'acik_ofis');
create temp table x_lb_own2 as select * from public.acik_ofis_leaderboard(50);
select t.logout();
select t.ok(not exists (select * from x_lb_compat2 except select * from x_lb_own2) and not exists (select * from x_lb_own2 except select * from x_lb_compat2)
        and (select count(*) from x_lb_own2 where is_me) = 1, 'X6 same for a logged-in player (own row flagged)');
select t.ok((select score from x_lb_compat where nickname = 'Oyuncu Bir') = (select best_score from public.acik_ofis_saves where user_id = :'u1')
        and (select stage from x_lb_compat where nickname = 'Oyuncu Bir') = 2 and (select (data->>'totalEarned')::numeric from public.acik_ofis_saves where user_id = :'u1') = 0,
            'X7 compat path reads Açık Ofis best_score/best_stage (current save is a fresh reset with totalEarned 0)');

-- per-game RPCs never touch the other game
create temp table x_before as select 'ao' g, data, revision, best_score from public.acik_ofis_saves where user_id = :'u1'
                              union all select 'k', data, revision, best_score from public.kodhane_saves where user_id = :'u1';
select t.login(:'u1');
select public.kodhane_reset_save();
select t.logout();
select t.ok((select row(data, revision, best_score) from public.acik_ofis_saves where user_id = :'u1') = (select row(data, revision, best_score) from x_before where g = 'ao'),
            'X8 kodhane_reset_save leaves the Açık Ofis row untouched');
select t.login(:'u1');
select public.acik_ofis_reset_save();
select t.logout();
select t.ok((select revision from public.kodhane_saves where user_id = :'u1') = (select revision + 1 from x_before where g = 'k'),
            'X9 acik_ofis_reset_save leaves the Kodhane row untouched (only the Kodhane reset bumped it)');
-- a nickname change in kodhane_profiles (the master until the split) shows on the compat list at once; acik_ofis_profiles
-- catches up when the Açık Ofis migration is re-run (runner checks that as M3)
update public.kodhane_profiles set nickname = 'Oyuncu Yeni' where user_id = :'u2';
select t.ok(exists (select 1 from public.kodhane_leaderboard(50, 'acik_ofis') where nickname = 'Oyuncu Yeni')
        and exists (select 1 from public.acik_ofis_leaderboard(50) where nickname = 'Oyuncu İki'),
            'X10 before the split kodhane_profiles is the master: compat list shows the new nickname, acik_ofis_profiles lags until re-mirror');

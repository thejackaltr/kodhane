-- PARTIAL of supabase/ops/kodhane_v44b_delete_test.sh: runs first in every step after "create". Refuses (exception,
-- nothing done) unless the target is THE test account recorded by "create": same id, e-mail of the pattern
-- kodhane-deltest-YYYYMMDD-HHMMSS@example.invalid AND equal to the recorded one, created_at equal to the recorded instant,
-- never signed in, no identity, no profile in either game, no Açık Ofis save. A real player can never match.
do $guard$
declare u record;
begin
  if current_setting('kd.t_email') !~ '^kodhane-deltest-[0-9]{8}-[0-9]{6}@example\.invalid$' then
    raise exception 'STOP: recorded e-mail is not a test address';
  end if;
  select * into u from auth.users where id = current_setting('kd.t_uid')::uuid;
  if not found then raise exception 'STOP: test user % not found', current_setting('kd.t_uid'); end if;
  if u.email is distinct from current_setting('kd.t_email') or u.email !~ '^kodhane-deltest-[0-9]{8}-[0-9]{6}@example\.invalid$' then
    raise exception 'STOP: user % is not the recorded test account (e-mail differs)', u.id;
  end if;
  if to_char(u.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US') is distinct from current_setting('kd.t_created') then
    raise exception 'STOP: user % created_at differs from the instant recorded at creation', u.id;
  end if;
  if u.last_sign_in_at is not null or exists (select 1 from auth.identities i where i.user_id = u.id)
     or exists (select 1 from public.kodhane_profiles p where p.user_id = u.id)
     or (to_regclass('public.acik_ofis_profiles') is not null and exists (select 1 from public.acik_ofis_profiles p where p.user_id = u.id))
     or (to_regclass('public.acik_ofis_saves') is not null and exists (select 1 from public.acik_ofis_saves s where s.user_id = u.id)) then
    raise exception 'STOP: user % has sign-ins / identities / profiles / Açık Ofis data: not a test account', u.id;
  end if;
end $guard$;

-- Hallen-App: Update 3 (nach Update 2 ausführen)
-- Neu: Mitkommende ohne Handy (z. B. Kinder). Ein Teilnehmer legt sie an, sagt für sie zu,
-- meldet sie als "da". Jede Person belegt einen eigenen Platz und kostet wie alle anderen;
-- Zahlungen und offene Beträge sieht der Teilnehmer gesammelt.

alter table public.members add column if not exists guardian_id uuid references public.members(id);
grant select (guardian_id) on public.members to authenticated;

-- Namen: Erwachsene weiterhin eindeutig; Mitkommende nur eindeutig je Teilnehmer
drop index if exists public.members_name_active;
create unique index if not exists members_name_active on public.members (lower(trim(name))) where active and guardian_id is null;
create unique index if not exists members_companion_name on public.members (guardian_id, lower(trim(name))) where active and guardian_id is not null;

-- Ich und meine aktiven Mitkommenden
create or replace function public.my_people() returns setof uuid
language sql stable security definer set search_path = public as $$
  select id from members where active and (id = public.my_member_id() or guardian_id = public.my_member_id())
$$;

-- Zum Lesen von Geld auch entfernte Mitkommende (damit offene Beträge sichtbar bleiben)
create or replace function public.my_people_all() returns setof uuid
language sql stable security definer set search_path = public as $$
  select id from members where public.my_member_id() is not null
    and (id = public.my_member_id() or guardian_id = public.my_member_id())
$$;

create or replace function public.can_act_for(who uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select who is not null and who in (select public.my_people())
$$;

-- Leserechte: eigene + Mitkommende
drop policy if exists plans_read on public.member_plans;
create policy plans_read on public.member_plans for select to authenticated
  using (public.is_admin() or member_id in (select public.my_people_all()));
drop policy if exists pay_read on public.payments;
create policy pay_read on public.payments for select to authenticated
  using (public.is_admin() or member_id in (select public.my_people_all()));
drop policy if exists signups_read on public.signups;
create policy signups_read on public.signups for select to authenticated
  using (public.is_admin() or public.is_helper() or member_id in (select public.my_people()));

-- Mitkommende verwalten
create or replace function public.add_companion(display_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_member_id(); n text := trim(display_name); mid uuid;
begin
  if me is null then raise exception 'kein Mitglied'; end if;
  perform pg_advisory_xact_lock(hashtext(me::text));
  if exists (select 1 from members where id = me and guardian_id is not null) then raise exception 'nicht erlaubt'; end if;
  if char_length(n) not between 1 and 30 then raise exception 'Name ungültig'; end if;
  if (select count(*) from members where guardian_id = me and active) >= 6 then raise exception 'Höchstens 6 Mitkommende'; end if;
  insert into members (name, guardian_id) values (n, me) returning id into mid;
  return mid;
end $$;

create or replace function public.remove_companion(who uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_member_id();
begin
  if me is null then raise exception 'kein Mitglied'; end if;
  update members set active = false where id = who and guardian_id = me;
  if not found then raise exception 'nicht erlaubt'; end if;
  delete from signups s where s.member_id = who
    and public.session_day(s.session_key) >= public.berlin_today()
    and not exists (select 1 from attendance a where a.session_key = s.session_key and a.member_id = who
                    and coalesce(a.admin_override, a.self_checked));
end $$;

-- Zusage / Absage / da für mich oder meine Mitkommenden
create or replace function public.sign_up(k text, who uuid) returns int
language plpgsql security definer set search_path = public as $$
declare d date := public.session_day(k);
begin
  if not public.can_act_for(who) then raise exception 'nicht erlaubt'; end if;
  perform pg_advisory_xact_lock(hashtext(k));
  if d is null or d < public.berlin_today() then raise exception 'Termin nicht verfügbar'; end if;
  if exists (select 1 from session_overrides where session_key = k and cancelled) then raise exception 'Termin abgesagt'; end if;
  insert into signups (session_key, member_id) values (k, who) on conflict do nothing;
  return public.list_position(k, who);
end $$;

create or replace function public.withdraw(k text, who uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d date := public.session_day(k);
begin
  if not public.can_act_for(who) then raise exception 'nicht erlaubt'; end if;
  perform pg_advisory_xact_lock(hashtext(k));
  if d is null or d < public.berlin_today() then raise exception 'Termin ist vorbei'; end if;
  if exists (select 1 from attendance where session_key = k and member_id = who
             and coalesce(admin_override, self_checked)) then
    raise exception 'Schon als „da“ gemeldet';
  end if;
  delete from signups where session_key = k and member_id = who;
end $$;

create or replace function public.check_in(k text, who uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d date := public.session_day(k); mx int; p numeric; pos int;
begin
  if not public.can_act_for(who) then raise exception 'nicht erlaubt'; end if;
  perform pg_advisory_xact_lock(hashtext(k));
  if d is null or d <> public.berlin_today() then raise exception '„Ich bin da“ geht nur am Termintag'; end if;
  if exists (select 1 from session_overrides where session_key = k and cancelled) then raise exception 'Termin abgesagt'; end if;
  select max_players, price into mx, p from settings where id = 1;
  pos := public.list_position(k, who);
  if pos is null then
    insert into signups (session_key, member_id) values (k, who);
    pos := public.list_position(k, who);
  end if;
  if pos > mx then raise exception 'Steht auf der Warteliste'; end if;
  insert into attendance (session_key, member_id, self_checked, price) values (k, who, true, p)
  on conflict (session_key, member_id) do update set self_checked = true;
end $$;

create or replace function public.check_out(k text, who uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.can_act_for(who) then raise exception 'nicht erlaubt'; end if;
  update attendance set self_checked = false
   where session_key = k and member_id = who and admin_override is null
     and public.session_day(k) = public.berlin_today();
end $$;

-- Liste: Wartende sieht man für sich und die eigenen Mitkommenden
create or replace function public.roster(k text)
returns table (member_id uuid, name text, pos int, waiting boolean)
language sql stable security definer set search_path = public as $$
  with s as (
    select su.member_id, m.name, row_number() over (order by su.created_at, su.id)::int as pos
    from signups su join members m on m.id = su.member_id
    where su.session_key = k
  ), mx as (select max_players from settings where id = 1)
  select s.member_id, s.name, s.pos, s.pos > mx.max_players
  from s, mx
  where public.is_member_or_admin()
    and (s.pos <= mx.max_players or public.is_admin() or public.is_helper()
         or s.member_id in (select public.my_people()))
  order by s.pos
$$;

-- Beitritt: Namen nur gegen Erwachsene prüfen (Mitkommende dürfen gleich heißen)
create or replace function public.join_group(code text, display_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare mid uuid; act boolean; n text := trim(display_name);
begin
  if auth.uid() is null then raise exception 'nicht angemeldet'; end if;
  if not exists (select 1 from settings where id = 1 and invite_code = code) then
    raise exception 'Einladungslink ungültig';
  end if;
  select id, active into mid, act from members where user_id = auth.uid();
  if mid is not null and act then return mid; end if;
  if mid is not null and not act then raise exception 'Du wurdest entfernt – bitte beim Verwalter melden'; end if;
  if char_length(n) not between 1 and 30 then raise exception 'Name ungültig'; end if;
  if exists (select 1 from members where active and guardian_id is null and lower(trim(name)) = lower(n)) then
    raise exception 'Name schon vergeben – falls du das bist: Geräte-Code beim Verwalter holen';
  end if;
  insert into members (user_id, name) values (auth.uid(), n) returning id into mid;
  return mid;
end $$;

revoke execute on function public.my_people_all() from anon, public;
grant execute on function public.my_people_all() to authenticated;
revoke execute on function public.my_people(), public.can_act_for(uuid), public.add_companion(text),
  public.remove_companion(uuid), public.sign_up(text, uuid), public.withdraw(text, uuid),
  public.check_in(text, uuid), public.check_out(text, uuid) from anon, public;
grant execute on function public.my_people(), public.can_act_for(uuid), public.add_companion(text),
  public.remove_companion(uuid), public.sign_up(text, uuid), public.withdraw(text, uuid),
  public.check_in(text, uuid), public.check_out(text, uuid), public.roster(text) to authenticated;

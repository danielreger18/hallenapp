-- Hallen-App: Datenbank-Schema mit Zugriffsregeln (Row Level Security)
-- Ausführen: Supabase-Projekt > SQL Editor > New query > alles einfügen > Run.
-- Das Skript ist für ein leeres Projekt gedacht.
--
-- Rollen:
--   Verwalter (Onkel): echtes Konto mit E-Mail. Wird nach seiner Registrierung
--                      einmalig per SQL freigeschaltet (siehe ganz unten).
--   Teilnehmer:        anonyme Anmeldung (Gerät) + Einladungscode + Name.
--   Helfer:            Teilnehmer mit Häkchen "darf Warteliste sehen".
--
-- Grundsatz: Alle Tabellen haben RLS. Ohne passende Regel sieht niemand etwas.
-- Teilnehmer schreiben nie direkt in Tabellen, sondern nur über geprüfte Funktionen.

create extension if not exists pgcrypto;

-- ---------- Tabellen ----------
create table public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

create table public.settings (
  id int primary key default 1 check (id = 1),
  price numeric(8,2) not null default 2,
  flat_price numeric(8,2) not null default 30,
  flat_from date not null default '2026-11-30',
  flat_until date not null default '2026-12-31',
  max_players int not null default 18 check (max_players between 1 and 99),
  start_time time not null default '20:00',
  end_time time not null default '22:00',
  anchor date not null default '2026-11-30',          -- Montag mit Fußball
  loc_mo text not null default 'Isengarten-Halle',
  loc_di text not null default 'Wiederhol-Halle',
  invite_code text not null default encode(gen_random_bytes(9), 'hex')
);
insert into public.settings default values;

create table public.members (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users(id) on delete set null,
  name text not null check (char_length(trim(name)) between 1 and 30),
  active boolean not null default true,
  helper boolean not null default false,
  created_at timestamptz not null default now()
);
create unique index members_name_active on public.members (lower(trim(name))) where active;

-- Tarif getrennt, damit andere Teilnehmer ihn nicht sehen
create table public.member_plans (
  member_id uuid primary key references public.members(id) on delete cascade,
  flat_amount numeric(8,2) not null,
  flat_from date not null,
  flat_until date not null
);

create table public.extra_sessions (
  id uuid primary key default gen_random_uuid(),
  day date not null,
  start_time time not null,
  end_time time not null check (end_time > start_time),
  sport text not null check (sport in ('Fußball','Volleyball')),
  loc text not null check (char_length(loc) <= 60)
);

-- Schlüssel eines Termins: Datum (YYYY-MM-DD) für Regeltermine, sonst 'x' || uuid
create table public.session_overrides (
  session_key text primary key,
  cancelled boolean not null default false,
  sport text check (sport in ('Fußball','Volleyball')),
  loc text check (char_length(loc) <= 60)
);

create table public.signups (
  id bigint generated always as identity,
  session_key text not null,
  member_id uuid not null references public.members(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (session_key, member_id)
);

create table public.attendance (
  session_key text not null,
  member_id uuid not null references public.members(id) on delete cascade,
  self_checked boolean not null default false,
  admin_override boolean,                 -- null = keine Korrektur
  price numeric(8,2) not null,            -- Preis zum Zeitpunkt der Erfassung
  primary key (session_key, member_id)
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.members(id),
  amount numeric(10,2) not null check (amount > 0),
  day date not null default current_date,
  note text check (char_length(note) <= 100)
);

create table public.incomes (
  id uuid primary key default gen_random_uuid(),
  day date not null,
  amount numeric(10,2) not null check (amount > 0),
  label text not null check (char_length(label) <= 60),
  category text not null default 'Sonstige Einnahme',
  receipt text check (receipt is null or char_length(receipt) < 400000)                           -- verkleinertes Foto als data-URL
);

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  day date not null,                      -- Zahltag; in der Zukunft = geplant
  amount numeric(10,2) not null check (amount > 0),
  label text not null check (char_length(label) <= 60),
  category text not null check (category in ('Hallenmiete','Material','Sonstiges')),
  monthly boolean not null default false,
  end_day date,
  receipt text check (receipt is null or char_length(receipt) < 400000)
);

-- ---------- Hilfsfunktionen ----------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from admins where user_id = auth.uid()) $$;

create or replace function public.my_member_id() returns uuid
language sql stable security definer set search_path = public as
$$ select id from members where user_id = auth.uid() and active $$;

create or replace function public.is_helper() returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce((select helper from members where user_id = auth.uid() and active), false) $$;

create or replace function public.is_member_or_admin() returns boolean
language sql stable security definer set search_path = public as
$$ select public.is_admin() or public.my_member_id() is not null $$;

create or replace function public.berlin_today() returns date
language sql stable as $$ select (now() at time zone 'Europe/Berlin')::date $$;

-- Datum eines Termins; null, wenn es den Termin nicht gibt
create or replace function public.session_day(k text) returns date
language plpgsql stable security definer set search_path = public as $$
declare d date; a date;
begin
  if k like 'x%' then
    if not public.is_member_or_admin() then return null; end if;
    select day into d from extra_sessions where id::text = substr(k, 2);
    return d;
  end if;
  begin d := k::date; exception when others then return null; end;
  if k <> to_char(d, 'YYYY-MM-DD') then return null; end if;   -- nur kanonische Schreibweise
  select anchor into a from settings where id = 1;
  if d < a or extract(isodow from d) not in (1, 2) then return null; end if;
  return d;
end $$;

-- Platz in der Liste (1 = erster); null wenn nicht eingetragen
create or replace function public.list_position(k text, m uuid) returns int
language sql stable security definer set search_path = public as $$
  select pos from (
    select member_id, row_number() over (order by created_at, id) as pos
    from signups where session_key = k
  ) t where member_id = m
$$;

-- ---------- RLS einschalten ----------
alter table public.admins enable row level security;
alter table public.settings enable row level security;
alter table public.members enable row level security;
alter table public.member_plans enable row level security;
alter table public.extra_sessions enable row level security;
alter table public.session_overrides enable row level security;
alter table public.signups enable row level security;
alter table public.attendance enable row level security;
alter table public.payments enable row level security;
alter table public.incomes enable row level security;
alter table public.expenses enable row level security;

-- Nicht angemeldete Besucher bekommen gar keinen Tabellenzugriff
revoke all on all tables in schema public from anon;

-- ---------- Regeln ----------
create policy admins_self on public.admins for select to authenticated using (user_id = auth.uid());

create policy settings_read on public.settings for select to authenticated using (public.is_member_or_admin());
create policy settings_admin on public.settings for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- Namen und Helfer-Häkchen sehen alle Mitglieder (für Zusagen/Anwesenheit)
create policy members_read on public.members for select to authenticated using (public.is_member_or_admin());
create policy members_admin on public.members for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Tarif: nur Verwalter und die Person selbst
create policy plans_read on public.member_plans for select to authenticated
  using (public.is_admin() or member_id = public.my_member_id());
create policy plans_admin on public.member_plans for all to authenticated using (public.is_admin()) with check (public.is_admin());

create policy extra_read on public.extra_sessions for select to authenticated using (public.is_member_or_admin());
create policy extra_admin on public.extra_sessions for all to authenticated using (public.is_admin()) with check (public.is_admin());

create policy ovr_read on public.session_overrides for select to authenticated using (public.is_member_or_admin());
create policy ovr_admin on public.session_overrides for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Zusagen: Verwalter und Helfer sehen alles (inkl. Warteliste), andere nur ihre eigenen.
-- Die bestätigte Liste für alle liefert die Funktion roster().
create policy signups_read on public.signups for select to authenticated
  using (public.is_admin() or public.is_helper() or member_id = public.my_member_id());
create policy signups_admin on public.signups for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Anwesenheit sehen alle Mitglieder; schreiben nur Verwalter (Teilnehmer über check_in)
create policy att_read on public.attendance for select to authenticated using (public.is_member_or_admin());
create policy att_admin on public.attendance for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Geld: Zahlungen nur Verwalter + eigene; Einnahmen/Ausgaben nur Verwalter
create policy pay_read on public.payments for select to authenticated
  using (public.is_admin() or member_id = public.my_member_id());
create policy pay_admin on public.payments for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy inc_admin on public.incomes for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy exp_admin on public.expenses for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ---------- Funktionen für Teilnehmer ----------
-- Beitritt über Einladungslink (Gerät ist anonym angemeldet)
create or replace function public.join_group(code text, display_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare mid uuid; n text := trim(display_name);
begin
  if auth.uid() is null then raise exception 'nicht angemeldet'; end if;
  if not exists (select 1 from settings where id = 1 and invite_code = code) then
    raise exception 'Einladungslink ungültig';
  end if;
  select id into mid from members where user_id = auth.uid();
  if mid is not null then return mid; end if;
  if char_length(n) not between 1 and 30 then raise exception 'Name ungültig'; end if;
  if exists (select 1 from members where active and lower(trim(name)) = lower(n)) then
    raise exception 'Name schon vergeben';
  end if;
  insert into members (user_id, name) values (auth.uid(), n) returning id into mid;
  return mid;
end $$;

-- Zusagen ("Ich komme"); ab Platz max_players+1 automatisch Warteliste
create or replace function public.sign_up(k text) returns int
language plpgsql security definer set search_path = public as $$
declare mid uuid := public.my_member_id(); d date := public.session_day(k);
begin
  if mid is null then raise exception 'kein Mitglied'; end if;
  perform pg_advisory_xact_lock(hashtext(k));
  if d is null or d < public.berlin_today() then raise exception 'Termin nicht verfügbar'; end if;
  if exists (select 1 from session_overrides where session_key = k and cancelled) then raise exception 'Termin abgesagt'; end if;
  insert into signups (session_key, member_id) values (k, mid) on conflict do nothing;
  return public.list_position(k, mid);
end $$;

-- Absagen; der Erste der Warteliste rückt automatisch nach (Reihenfolge = Zeitpunkt)
create or replace function public.withdraw(k text) returns void
language plpgsql security definer set search_path = public as $$
declare mid uuid := public.my_member_id(); d date := public.session_day(k);
begin
  if mid is null then raise exception 'kein Mitglied'; end if;
  perform pg_advisory_xact_lock(hashtext(k));
  if d is null or d < public.berlin_today() then raise exception 'Termin ist vorbei'; end if;
  if exists (select 1 from attendance where session_key = k and member_id = mid
             and coalesce(admin_override, self_checked)) then
    raise exception 'Du bist schon eingecheckt';
  end if;
  delete from signups where session_key = k and member_id = mid;
end $$;

-- "Ich bin da": nur am Termintag, nur mit bestätigtem Platz (oder freiem Platz)
create or replace function public.check_in(k text) returns void
language plpgsql security definer set search_path = public as $$
declare mid uuid := public.my_member_id(); d date := public.session_day(k);
        mx int; p numeric; pos int;
begin
  if mid is null then raise exception 'kein Mitglied'; end if;
  perform pg_advisory_xact_lock(hashtext(k));
  if d is null or d <> public.berlin_today() then raise exception '„Ich bin da“ geht nur am Termintag'; end if;
  if exists (select 1 from session_overrides where session_key = k and cancelled) then raise exception 'Termin abgesagt'; end if;
  select max_players, price into mx, p from settings where id = 1;
  pos := public.list_position(k, mid);
  if pos is null then
    insert into signups (session_key, member_id) values (k, mid);
    pos := public.list_position(k, mid);
  end if;
  if pos > mx then raise exception 'Du stehst auf der Warteliste'; end if;
  insert into attendance (session_key, member_id, self_checked, price) values (k, mid, true, p)
  on conflict (session_key, member_id) do update set self_checked = true;
end $$;

create or replace function public.check_out(k text) returns void
language plpgsql security definer set search_path = public as $$
declare mid uuid := public.my_member_id();
begin
  if mid is null then raise exception 'kein Mitglied'; end if;
  update attendance set self_checked = false
   where session_key = k and member_id = mid and admin_override is null
     and public.session_day(k) = public.berlin_today();
end $$;

-- Liste eines Termins für die Anzeige:
-- bestätigte Plätze für alle; Wartende nur für Verwalter/Helfer oder die Person selbst
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
         or s.member_id = public.my_member_id())
  order by s.pos
$$;

-- Anzahl Zusagen (ohne Namen der Warteliste) für die Terminübersicht
create or replace function public.session_counts(keys text[])
returns table (session_key text, total int)
language sql stable security definer set search_path = public as $$
  select su.session_key,
         case when public.is_admin() or public.is_helper() then count(*)::int
              else least(count(*)::int, (select max_players from settings where id = 1)) end
  from signups su
  where public.is_member_or_admin() and su.session_key = any(keys)
  group by su.session_key
$$;

-- Einladungscode nur für den Verwalter; neu erzeugen macht alte Links ungültig
create or replace function public.get_invite_code() returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'nur Verwalter'; end if;
  return (select invite_code from settings where id = 1);
end $$;

create or replace function public.new_invite_code() returns text
language plpgsql security definer set search_path = public, extensions as $$
declare c text := encode(gen_random_bytes(9), 'hex');
begin
  if not public.is_admin() then raise exception 'nur Verwalter'; end if;
  update settings set invite_code = c where id = 1;
  return c;
end $$;

-- Funktionen nur für angemeldete Nutzer
revoke execute on all functions in schema public from anon, public;
grant execute on function public.join_group(text, text), public.sign_up(text), public.withdraw(text),
  public.check_in(text), public.check_out(text), public.roster(text), public.session_counts(text[]),
  public.is_admin(), public.my_member_id(), public.is_helper(), public.is_member_or_admin(),
  public.berlin_today(), public.session_day(text), public.get_invite_code(), public.new_invite_code()
  to authenticated;
-- list_position bleibt intern (verrät sonst Wartelisten-Plätze)
revoke execute on function public.list_position(text, uuid) from authenticated, anon, public;

-- Künftige Tabellen/Funktionen bekommen nicht automatisch Rechte
alter default privileges for role postgres in schema public revoke all on tables from anon;
alter default privileges for role postgres in schema public revoke execute on functions from anon, public;
revoke truncate on all tables in schema public from anon, authenticated;

-- Einladungscode und Konto-IDs nicht für Mitglieder lesbar (Spaltenrechte)
revoke select on public.settings from authenticated;
grant select (id, price, flat_price, flat_from, flat_until, max_players, start_time, end_time,
  anchor, loc_mo, loc_di) on public.settings to authenticated;
revoke select on public.members from authenticated;
grant select (id, name, active, helper, created_at) on public.members to authenticated;

-- ---------- Update 1 (bereits enthalten) ----------

alter table public.members add column if not exists claim_code text;
-- claim_code ist für Mitglieder nicht lesbar (Spaltenrechte aus dem Setup gelten weiter)

-- Verwalter: Code für eine Person erzeugen; trennt das alte Gerät
create or replace function public.make_claim_code(mid uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare c text := upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 8));
begin
  if not public.is_admin() then raise exception 'nur Verwalter'; end if;
  update members set claim_code = c, user_id = null where id = mid and active;
  if not found then raise exception 'Person nicht gefunden'; end if;
  return c;
end $$;

-- Teilnehmer: mit Code den eigenen Platz übernehmen
create or replace function public.claim_member(claim text) returns uuid
language plpgsql security definer set search_path = public as $$
declare mid uuid;
begin
  if auth.uid() is null then raise exception 'nicht angemeldet'; end if;
  if public.my_member_id() is not null then raise exception 'Dieses Gerät ist schon jemandem zugeordnet'; end if;
  update members set user_id = null where user_id = auth.uid();   -- alte, entfernte Zuordnung lösen
  update members set user_id = auth.uid(), claim_code = null
   where active and claim_code is not null and claim_code = upper(trim(claim))
  returning id into mid;
  if mid is null then raise exception 'Code ungültig'; end if;
  return mid;
end $$;

-- Beitritt: entfernte Personen klar abweisen
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
  if exists (select 1 from members where active and lower(trim(name)) = lower(n)) then
    raise exception 'Name schon vergeben – falls du das bist: Geräte-Code beim Verwalter holen';
  end if;
  insert into members (user_id, name) values (auth.uid(), n) returning id into mid;
  return mid;
end $$;

-- Extra-Termin sicher löschen (alles in einer Transaktion, nicht wenn schon jemand da war)
create or replace function public.delete_extra(k text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'nur Verwalter'; end if;
  if exists (select 1 from attendance where session_key = k and coalesce(admin_override, self_checked)) then
    raise exception 'Es gibt schon Anwesenheiten – bitte absagen statt löschen';
  end if;
  delete from signups where session_key = k;
  delete from attendance where session_key = k;
  delete from session_overrides where session_key = k;
  delete from extra_sessions where id::text = substr(k, 2);
end $$;

revoke execute on function public.make_claim_code(uuid), public.claim_member(text), public.delete_extra(text) from anon, public;
grant execute on function public.make_claim_code(uuid), public.claim_member(text), public.delete_extra(text),
  public.join_group(text, text) to authenticated;

-- ---------- Update 2 (bereits enthalten) ----------

grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- Einladungscode, Geräte-Codes und Konto-IDs bleiben für Mitglieder unlesbar (nur ausgewählte Spalten)
revoke select on public.settings from authenticated;
grant select (id, price, flat_price, flat_from, flat_until, max_players, start_time, end_time,
  anchor, loc_mo, loc_di) on public.settings to authenticated;
revoke select on public.members from authenticated;
grant select (id, name, active, helper, created_at) on public.members to authenticated;

-- Nicht angemeldete Besucher weiterhin ohne Zugriff
revoke all on all tables in schema public from anon;

-- ---------- Verwalter freischalten (später, einmalig) ----------
-- 1. Der Onkel registriert sich in der App mit seiner E-Mail.
-- 2. Dann diese Zeile mit seiner E-Mail ausführen:
-- insert into public.admins (user_id) select id from auth.users where email = 'EMAIL-DES-ONKELS';

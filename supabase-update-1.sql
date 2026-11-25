-- Hallen-App: Update 1 (nach supabase-setup.sql ausführen)
-- Neu: Geräte-Code, damit Teilnehmer ihren Platz auf einem neuen Gerät/Browser wieder übernehmen können
--      (auch Personen, die der Verwalter selbst angelegt hat). Entfernte Personen bekommen eine klare Meldung.

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

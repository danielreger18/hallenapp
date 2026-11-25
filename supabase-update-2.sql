-- Hallen-App: Update 2 (nach Update 1 ausführen)
-- Behebt "permission denied for table ...": Dieses Supabase-Projekt vergibt für neue Tabellen
-- keine automatischen Rechte. Hier werden sie ausdrücklich gesetzt. Die Zeilen-Regeln (RLS)
-- bleiben unverändert und entscheiden weiterhin, wer welche Zeilen sieht oder ändert.

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

# Hallen-App

Handy-Web-App (PWA) für die Hallensport-Gruppe: Termine Mo + Di, Zusagen mit Warteliste, „Ich bin da“, Beiträge, Kasse und Kassenbuch.

- **App:** `index.html` (läuft über GitHub Pages). Demo ohne Datenbank: `index.html?demo`
- **Datenbank:** Supabase. Schema und Zugriffsregeln: `supabase-setup.sql` (enthält Update 1), Nachtrag für bestehende Projekte: `supabase-update-1.sql`
- `supabase.js` ist supabase-js 2.119.0 (UMD), lokal mitgeliefert.
- Der Publishable key im Code ist öffentlich; der Schutz der Daten liegt in den RLS-Regeln der Datenbank.

## Verwalter freischalten
Der Verwalter registriert sich in der App (Verwalter-Anmeldung → Konto anlegen) und bestätigt seine E-Mail. Danach einmalig im Supabase SQL Editor:

```sql
insert into public.admins (user_id) select id from auth.users where email = 'EMAIL-DES-VERWALTERS';
```

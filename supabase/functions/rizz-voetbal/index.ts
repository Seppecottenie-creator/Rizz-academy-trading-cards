// RIZZ ACADEMY — functie "rizz-voetbal": haalt de voetbalwedstrijden op voor het Sportsbook
//
// Elk uur aangeroepen door pg_cron (zie update-26-voetbal.sql) met {"action": "sync"}.
// Haalt de wedstrijden van de afgelopen 3 en de komende 13 dagen op bij football-data.org (gratis):
// Champions League, Premier League, Serie A, La Liga en Ligue 1. Afgelopen wedstrijden worden meteen
// uitbetaald (fb_sync in de database). Pro League en Nations League voegt de admin zelf toe.
//
// Nodig: een gratis sleutel van football-data.org, in Supabase bewaard als geheim FOOTBALL_DATA_KEY
// (Edge Functions -> Secrets). De sleutel komt nooit in de site.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const COMPETITIONS = ['CL', 'PL', 'SA', 'PD', 'FL1'];
const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const day = (offset: number) => new Date(Date.now() + offset * 864e5).toISOString().slice(0, 10);

type ApiMatch = {
  id: number; utcDate: string; status: string;
  competition: { code: string };
  homeTeam: { name: string; shortName?: string }; awayTeam: { name: string; shortName?: string };
  score: { fullTime: { home: number | null; away: number | null }; regularTime?: { home: number | null; away: number | null } };
};

function mapStatus(s: string) {
  if (s === 'FINISHED' || s === 'AWARDED') return 'finished';
  if (s === 'CANCELLED' || s === 'POSTPONED' || s === 'SUSPENDED') return 'cancelled';
  return 'scheduled'; // SCHEDULED, TIMED, IN_PLAY, PAUSED
}

async function fetchRange(key: string, from: string, to: string): Promise<ApiMatch[]> {
  const url = `https://api.football-data.org/v4/matches?competitions=${COMPETITIONS.join(',')}&dateFrom=${from}&dateTo=${to}`;
  const res = await fetch(url, { headers: { 'X-Auth-Token': key } });
  if (!res.ok) throw new Error(`football-data.org gaf ${res.status}: ${(await res.text()).slice(0, 200)}`);
  return (await res.json()).matches || [];
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const key = Deno.env.get('FOOTBALL_DATA_KEY');
  if (!key) return json({ error: 'Geen FOOTBALL_DATA_KEY ingesteld (Edge Functions -> Secrets).' }, 500);
  const { data: go } = await db.rpc('fb_should_sync');
  if (go === false) return json({ skipped: 'Minder dan 10 minuten geleden al opgehaald.' });
  try {
    // De gratis API geeft hooguit 10 dagen per vraag: twee vragen
    const all = [...await fetchRange(key, day(-3), day(5)), ...await fetchRange(key, day(6), day(13))];
    const matches = all.map(m => {
      const sc = m.score.regularTime && m.score.regularTime.home != null ? m.score.regularTime : m.score.fullTime; // na 90 minuten
      return {
        ext_id: m.id, competition: m.competition.code, kickoff: m.utcDate, status: mapStatus(m.status),
        home: m.homeTeam.shortName || m.homeTeam.name, away: m.awayTeam.shortName || m.awayTeam.name,
        home_goals: sc.home, away_goals: sc.away,
      };
    }).filter(m => m.home && m.away && (m.status !== 'finished' || (m.home_goals != null && m.away_goals != null)));
    const { data, error } = await db.rpc('fb_sync', { p_matches: matches });
    if (error) throw new Error(error.message);
    return json(data);
  } catch (e) {
    return json({ error: (e as Error).message }, 502);
  }
});

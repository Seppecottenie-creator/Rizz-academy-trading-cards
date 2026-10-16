// RIZZ ACADEMY — functie "rizz-voetbal": haalt de voetbalwedstrijden op voor het Sportsbook
//
// Elk uur aangeroepen door pg_cron (zie update-26-voetbal.sql) met {"action": "sync"}.
// Haalt de wedstrijden van de afgelopen 3 en de komende 13 dagen op bij football-data.org (gratis):
// Champions League, Premier League, Serie A, La Liga en Ligue 1. Afgelopen wedstrijden worden meteen
// uitbetaald (fb_sync in de database).
//
// Quoteringen: twee keer per dag van the-odds-api.com (gratis: 500 vragen per maand). Per wedstrijd het
// gemiddelde van alle bookmakers wereldwijd. Daar komen ook de wedstrijden en uitslagen van de Pro League
// en de Nations League vandaan (die zitten niet in football-data.org).
//
// Nodig (Supabase -> Edge Functions -> Secrets), komen nooit in de site:
//   FOOTBALL_DATA_KEY  gratis sleutel van football-data.org
//   ODDS_API_KEY       gratis sleutel van the-odds-api.com (zonder: geen quoteringen, de admin kan ze zelf invullen)
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const COMPETITIONS = ['CL', 'PL', 'SA', 'PD', 'FL1'];
// Onze competitiecodes -> the-odds-api.com
const ODDS_SPORTS: Record<string, string> = {
  CL: 'soccer_uefa_champs_league', PL: 'soccer_epl', SA: 'soccer_italy_serie_a', PD: 'soccer_spain_la_liga',
  FL1: 'soccer_france_ligue_one', BPL: 'soccer_belgium_first_div', UNL: 'soccer_uefa_nations_league',
};
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

type OddsEvent = {
  id: string; commence_time: string; home_team: string; away_team: string;
  bookmakers: { markets: { key: string; outcomes: { name: string; price: number }[] }[] }[];
};
type ScoreEvent = { id: string; completed: boolean; home_team: string; away_team: string; scores: { name: string; score: string }[] | null };

async function oddsApi<T>(key: string, path: string, query: string): Promise<T> {
  const res = await fetch(`https://api.the-odds-api.com/v4/sports/${path}?apiKey=${key}&${query}`);
  if (res.status === 404 || res.status === 422) return [] as T; // competitie ligt stil (bv. geen Nations League)
  if (!res.ok) throw new Error(`the-odds-api.com gaf ${res.status}: ${(await res.text()).slice(0, 200)}`);
  return await res.json();
}

// Gemiddelde quotering van alle bookmakers voor thuis / gelijk / uit
function average(e: OddsEvent) {
  const sum = { o1: 0, ox: 0, o2: 0 }; let n = 0;
  for (const b of e.bookmakers || []) {
    const h2h = b.markets.find(m => m.key === 'h2h'); if (!h2h) continue;
    const get = (name: string) => h2h.outcomes.find(o => o.name === name)?.price;
    const o1 = get(e.home_team), ox = get('Draw'), o2 = get(e.away_team);
    if (!o1 || !ox || !o2) continue;
    sum.o1 += o1; sum.ox += ox; sum.o2 += o2; n++;
  }
  return n ? { o1: sum.o1 / n, ox: sum.ox / n, o2: sum.o2 / n, books: n } : null;
}

async function syncOdds(key: string) {
  const { data: plan, error } = await db.rpc('fb_odds_plan');
  if (error) throw new Error(error.message);
  const out: Record<string, unknown> = {};
  if (plan.odds) {
    const comps = new Set<string>([...plan.comps, 'BPL', 'UNL']);
    const events = [];
    for (const comp of comps) {
      const sport = ODDS_SPORTS[comp]; if (!sport) continue;
      const list = await oddsApi<OddsEvent[]>(key, `${sport}/odds`, 'regions=eu,uk&markets=h2h&oddsFormat=decimal');
      for (const e of list) {
        const avg = average(e);
        if (avg) events.push({ odds_id: e.id, competition: comp, home: e.home_team, away: e.away_team, kickoff: e.commence_time, ...avg });
      }
    }
    const r = await db.rpc('fb_sync_odds', { p_events: events });
    if (r.error) throw new Error(r.error.message);
    out.odds = r.data;
  }
  if (plan.scores) {
    const scores = [];
    for (const comp of plan.score_comps as string[]) {
      const sport = ODDS_SPORTS[comp]; if (!sport) continue;
      const list = await oddsApi<ScoreEvent[]>(key, `${sport}/scores`, 'daysFrom=3');
      for (const e of list) {
        if (!e.completed || !e.scores) continue;
        const goals = (name: string) => Number(e.scores!.find(s => s.name === name)?.score);
        const h = goals(e.home_team), a = goals(e.away_team);
        if (Number.isInteger(h) && Number.isInteger(a)) scores.push({ odds_id: e.id, home_goals: h, away_goals: a });
      }
    }
    const r = await db.rpc('fb_sync_scores', { p_scores: scores });
    if (r.error) throw new Error(r.error.message);
    out.scores = r.data;
  }
  return out;
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
        home_alt: m.homeTeam.name, away_alt: m.awayTeam.name,
        home_goals: sc.home, away_goals: sc.away,
      };
    }).filter(m => m.home && m.away && (m.status !== 'finished' || (m.home_goals != null && m.away_goals != null)));
    const { data, error } = await db.rpc('fb_sync', { p_matches: matches });
    if (error) throw new Error(error.message);
    const oddsKey = Deno.env.get('ODDS_API_KEY');
    let odds: unknown = 'Geen ODDS_API_KEY ingesteld: geen quoteringen.';
    if (oddsKey) odds = await syncOdds(oddsKey).catch(e => ({ error: (e as Error).message }));
    return json({ ...data, odds });
  } catch (e) {
    return json({ error: (e as Error).message }, 502);
  }
});

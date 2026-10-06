// RIZZ ACADEMY — functie "rizz-push": pushmeldingen
//
// Acties (POST met JSON {"action": ...}):
//   key    -> geeft de publieke sleutel voor meldingen (de site heeft die nodig om je in te schrijven)
//   test   -> stuurt een testmelding naar jezelf (enkel ingelogd)
//   remind -> elke dag om 19u (Belgische tijd): herinnering voor wie zijn examen nog niet speelde.
//             Wordt elk uur aangeroepen door pg_cron (zie update-11-meldingen.sql); verstuurt enkel om 19u
//             en hooguit één keer per dag per toestel.
//
// De sleutels voor de meldingen maakt deze functie zelf aan bij de eerste keer en bewaart ze in de
// tabel push_config (enkel leesbaar voor de server). Je hoeft dus niets in te stellen.
import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const SITE = 'https://seppecottenie-creator.github.io/rizz-academy-trading-cards/';
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

const GAMES: Record<string, string> = {
  wordle: 'English: de Wordle', math: 'Math: Speed Math', hoops: 'Phys. Ed.: Free Throws', history: 'History: Which Came First?',
  launch: 'Physics: Cannon Shot', darts: 'Party: Darts', blackjack: 'Party: Blackjack',
};
const LINES = [
  'Geen F halen vandaag.',
  'De rest van het huis heeft al gespeeld.',
  'Je envelop wacht. Je cijfer ook.',
  'Wie niet speelt, verzamelt niets.',
];

type Sub = { endpoint: string; p256dh: string; auth: string };

async function vapid() {
  const { data } = await db.from('push_config').select('public_key, private_key').eq('id', 1).maybeSingle();
  if (data) return data;
  const k = webpush.generateVAPIDKeys();
  const { error } = await db.from('push_config').insert({ id: 1, public_key: k.publicKey, private_key: k.privateKey });
  if (error) { // tegelijk aangemaakt door een andere aanroep
    const { data: again } = await db.from('push_config').select('public_key, private_key').eq('id', 1).single();
    return again!;
  }
  return { public_key: k.publicKey, private_key: k.privateKey };
}

async function send(s: Sub, payload: Record<string, string>) {
  try {
    await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify(payload), { TTL: 4 * 3600 });
    return true;
  } catch (e) {
    const code = (e as { statusCode?: number }).statusCode;
    if (code === 404 || code === 410) await db.from('push_subscriptions').delete().eq('endpoint', s.endpoint); // toestel bestaat niet meer
    return false;
  }
}

const brusselsHour = () => Number(new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/Brussels', hour: 'numeric', hourCycle: 'h23' }).format(new Date()));

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
  try {
    const { action } = await req.json().catch(() => ({ action: '' }));
    const k = await vapid();
    webpush.setVapidDetails(SITE, k.public_key, k.private_key);

    if (action === 'key') return json({ key: k.public_key });

    if (action === 'test') {
      const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
      const { data: u } = await db.auth.getUser(token);
      if (!u?.user) return json({ error: 'Niet ingelogd.' }, 401);
      const { data: subs } = await db.from('push_subscriptions').select('endpoint, p256dh, auth').eq('user_id', u.user.id);
      let sent = 0;
      for (const s of subs || []) if (await send(s, { title: 'Rizz Academy', body: 'Meldingen staan aan. Om 19u krijg je een seintje als je examen nog open staat.', url: './', tag: 'rizz-test' })) sent++;
      return json({ sent });
    }

    if (action === 'remind') {
      if (brusselsHour() !== 19) return json({ skipped: 'enkel om 19u' });
      const { data: targets, error } = await db.rpc('push_targets');
      if (error) throw error;
      let sent = 0;
      for (const t of targets || []) {
        const line = LINES[Math.floor(Math.random() * LINES.length)];
        if (await send(t, { title: 'Je examen staat nog open', body: `${GAMES[t.game] || 'Het examen van vandaag'}. ${line}`, url: './?tab=today', tag: 'rizz-exam' })) sent++;
        await db.from('push_subscriptions').update({ last_sent: t.today }).eq('endpoint', t.endpoint);
      }
      return json({ sent });
    }

    return json({ error: 'Onbekende actie.' }, 400);
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});

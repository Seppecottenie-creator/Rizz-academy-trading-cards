# Genereert supabase/kaarten.sql met testkaarten voor alle vrienden.
# Gebruik: python3 tools/maak-kaarten.py
# Pas de lijsten hieronder aan en voer het script opnieuw uit.
import hashlib, pathlib

VRIENDEN = [  # (naam in het boek, korte naam op de kaart, bestandsnaam)
    ('Thomas', 'Thomas', 'thomas'), ('Seppe', 'Seppe', 'seppe'), ('Jules', 'Jules', 'jules'),
    ('Arthuur', 'Arthuur', 'arthuur'), ('Tuur', 'Tuur', 'tuur'), ('Stan Sabbe', 'Stan S.', 'stan-sabbe'),
    ('Stan Lavaert', 'Stan L.', 'stan-lavaert'), ('Gerben', 'Gerben', 'gerben'), ('Luca', 'Luca', 'luca'),
    ('Jakov', 'Jakov', 'jakov'), ('Casper', 'Casper', 'casper'), ('Wout', 'Wout', 'wout'),
    ('Thibault', 'Thibault', 'thibault'),
]

# Per slot een paar varianten; elke vriend krijgt er één (afwisselend), zodat niet alle pagina's gelijk zijn.
SLOTS = {
    1: [('Freshman {n}', 'Eerste dag op de campus en nu al verdwaald.'),
        ('Rookie {n}', 'Weet nog niet waar de aula is, wel waar de bar is.'),
        ('New Kid {n}', 'Stelt zich aan iedereen voor. Twee keer.')],
    2: [('Class Clown {n}', 'Lacht het hardst om zijn eigen grappen.'),
        ('Back Row {n}', 'Zit altijd achteraan. Voor het overzicht, zegt hij.'),
        ('Hall Pass {n}', 'Gaat even naar het toilet en komt na een uur terug.')],
    3: [('Gamer {n}', 'Nog één potje. Het is vier uur \'s nachts.'),
        ('Lag Lord {n}', 'Het lag aan de wifi. Het ligt altijd aan de wifi.'),
        ('Respawn {n}', 'Staat sneller op in de game dan in het echt.')],
    4: [('Card Shark {n}', 'Heeft altijd nog een troef achter de hand.'),
        ('Poker Face {n}', 'Niemand weet wat hij in handen heeft. Hijzelf ook niet.'),
        ('Dealer {n}', 'Wie deelt? Ik deel. Altijd.')],
    5: [('Beer Pong {n}', 'Mikt beter na het derde glas.'),
        ('{n} on Tap', 'Altijd vers getapt, nooit lauw.'),
        ('Keg Stand {n}', 'Ondersteboven is ook een standpunt.')],
    6: [('Night Owl {n}', 'Gaat "nog ééntje drinken" en is om zes uur thuis.'),
        ('Dancefloor {n}', 'Eerste op de dansvloer, laatste eraf.'),
        ('Afterparty {n}', 'Het feest begint pas als hij binnenkomt.')],
    7: [('Varsity Captain {n}', 'Draagt de jas, draagt het team.'),
        ('Prom King {n}', 'Gekroond op het bal en nooit meer afgezet.'),
        ('MVP {n}', 'Most Valuable Partyganger.')],
    8: [('Frat President {n}', 'Zijn kot, zijn regels.'),
        ('Homecoming Hero {n}', 'Scoort op het veld en daarbuiten.'),
        ("Dean's List {n}", 'Hoogste punten, minste slaap.')],
    9: [('Hall of Fame {n}', 'Legendary Rizz', 'Eén blik en het hele café is fan.'),
        ('Valedictorian {n}', 'Afscheidsspeech', 'Iedereen huilt, ook de tegenstander.'),
        ('Rizz Royalty {n}', 'Royal Decree', 'Wat hij zegt, gebeurt.')],
}

# Troostkaarten (rarity 'cat'): wie de Wordle niet oplost, moet nablijven.
DETENTION = [
    ('Te laat in de les', 'De wekker ging af. Hij niet.'),
    ('Kater van de eeuw', 'Nooit meer drinken. Tot vrijdag.'),
    ('Blauwtje', 'Ze had "een vriend". Natuurlijk.'),
    ('Gsm afgepakt', 'Krijg je terug op het einde van het jaar.'),
    ('Strafstudie', 'Honderd keer schrijven: ik zal de Wordle oplossen.'),
    ('Verloren bij beer pong', 'Alle bekers. Allemaal.'),
    ('Laatste trein gemist', 'Slaapt vannacht op de bank van iemand anders.'),
    ('Rage Quit', 'De controller heeft het niet overleefd.'),
    ('Ingedommeld in de aula', 'Wakker geworden in een andere les.'),
]

def roll(key, lo, hi):
    h = int(hashlib.md5(key.encode()).hexdigest(), 16)
    return lo + h % (hi - lo + 1)

def stats(key, rarity):
    r = {'common': ((55, 75), (14, 24), (10, 18)), 'epic': ((78, 92), (24, 32), (17, 24)),
         'legendary': ((95, 110), (32, 40), (22, 28)), 'cat': ((40, 52), (9, 15), (7, 12))}[rarity]
    return [roll(key + str(i), *rng) for i, rng in enumerate(r)]

def q(s):
    return 'null' if s is None else "'" + s.replace("'", "''") + "'"

rows = []
for vi, (person, short, slug) in enumerate(VRIENDEN):
    for slot in range(1, 10):
        rarity = 'common' if slot <= 6 else 'epic' if slot <= 8 else 'legendary'
        v = SLOTS[slot][(vi + slot) % len(SLOTS[slot])]
        name = v[0].format(n=short)
        hp, atk, df = stats(person + str(slot), rarity)
        if rarity == 'legendary':
            flavor, sname, sdesc, spow = 'Class of 2026.', v[1], v[2], roll(person + 'sp', 45, 55)
        else:
            flavor, sname, sdesc, spow = v[1], None, None, None
        rows.append((person, slot, name, rarity, hp, atk, df, f'cards/{slug}-{slot}.jpg', flavor, sname, sdesc, spow))
for i, (name, flavor) in enumerate(DETENTION, 1):
    hp, atk, df = stats('detention' + str(i), 'cat')
    rows.append(('Detention', i, name, 'cat', hp, atk, df, f'cards/detention-{i}.jpg', flavor, None, None, None))

lines = [f"  ({q(p)}, {s}, {q(n)}, {q(r)}, {hp}, {a}, {d}, {q(img)}, {q(f)}, {q(sn)}, {q(sd)}, {'null' if sp is None else sp})"
         for p, s, n, r, hp, a, d, img, f, sn, sd, sp in rows]

sql = f"""-- =====================================================================
-- RIZZ ACADEMY: testkaarten ({len(rows)} kaarten)
-- {len(VRIENDEN)} vrienden x 9 kaarten (slot 1-6 common, 7-8 epic, 9 legendary)
-- + 9 Detention-kaarten (troostkaarten, rarity 'cat').
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren: bestaande kaarten worden bijgewerkt, niet dubbel aangemaakt.
--
-- Afbeeldingen: upload ze later naar de map cards/ met exact de naam uit image_url
-- (bv. cards/thomas-1.jpg). Zolang een afbeelding ontbreekt, toont de site een
-- varsity-letter als tijdelijke illustratie.
-- Gegenereerd door tools/maak-kaarten.py.
-- =====================================================================
insert into public.cards (person, slot, name, rarity, hp, attack, defense, image_url, flavor_text, special_name, special_desc, special_power) values
{(','+chr(10)).join(lines)}
on conflict (person, slot) do update set
  name = excluded.name, rarity = excluded.rarity, hp = excluded.hp, attack = excluded.attack,
  defense = excluded.defense, image_url = excluded.image_url, flavor_text = excluded.flavor_text,
  special_name = excluded.special_name, special_desc = excluded.special_desc, special_power = excluded.special_power;
"""
out = pathlib.Path(__file__).resolve().parent.parent / 'supabase' / 'kaarten.sql'
out.write_text(sql, encoding='utf-8')
print(f'{out}: {len(rows)} kaarten')

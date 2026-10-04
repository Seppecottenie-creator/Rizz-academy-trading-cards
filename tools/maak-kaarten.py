# Genereert supabase/kaarten.sql met alle kaarten van de vriendengroep.
# Gebruik: python3 tools/maak-kaarten.py
# Pas de teksten hieronder aan en voer het script opnieuw uit.
#
# Per vriend 9 kaarten in volgorde van slot: 1-6 common, 7-8 epic, 9 legendary.
# 'foto' is het nummer van de foto in de map die per vriend werd aangeleverd
# (gesorteerd op bestandsnaam); tools/zet-fotos.py gebruikt dit om de foto's
# als cards/<bestandsnaam>-<slot>.jpg klaar te zetten.
import hashlib, pathlib

# (naam in het boek, bestandsnaam, map met foto's, kaarten)
# kaart = (foto, titel, citaat)  of voor de legendary: (foto, titel, citaat, special, uitleg special)
VRIENDEN = [
  ('Arthuur', 'arthuur', 'arthuur', [
    (1, 'De Vissenoog', 'Ik zie alles. Vooral jouw neus.'),
    (4, 'Het Stockmodel', 'Ook verkrijgbaar zonder watermerk.'),
    (5, 'De Nachtwaker', 'Nog eentje en dan ga ik. Echt.'),
    (6, 'De Pruillip', 'Ik ben niet boos. Ik ben teleurgesteld.'),
    (7, 'Mister Aloha', 'Ergens is het altijd vakantie.'),
    (8, 'Het Pokerface', 'Ik weet niks. Ik weet alles.'),
    (2, 'Front Row', 'LUIDER! IK HOOR JE NIET!'),
    (3, 'De Sommelier', 'Proeven is voor amateurs.'),
    (9, 'Het Schortje', 'Kalendermodel van juni tot augustus.', 'Schortje van Schaamte', 'Verblindt de tegenstander met pure zelfzekerheid.'),
  ]),
  ('Casper', 'casper', 'casper', [
    (3, 'Breaking News', 'Ja mama, ik ben al lang wakker.'),
    (4, 'De Uitbater', 'Laatste ronde? Dat bepaal ik.'),
    (6, 'Het Mini-Hoedje', 'Klein hoedje, grote plannen.'),
    (7, 'De Gym Bro', 'Leg day skippen? Nooit. Shirt skippen? Altijd.'),
    (8, 'Veiligheid Eerst', 'Je weet nooit wanneer het plafond aanvalt.'),
    (9, 'De Rekening', 'Wie zette dit allemaal op MIJN rekening?'),
    (1, 'De Bergkoning', 'IK BEN DE KONING VAN DEZE BERG!'),
    (5, 'Tinkerbell', 'Ik strooi geen feeënstof. Ik strooi rondjes.'),
    (2, 'De Reismand', 'Wat er in de mand zit? Gaat je niks aan.', 'Reismand-Defensie', 'Niemand weet wat erachter zit. Niemand wil het weten.'),
  ]),
  ('Gerben', 'gerben', 'gerben', [
    (1, 'De Mijnwerker', 'Hoeveel kost die Charizard?!'),
    (2, 'De Schuimkoning', 'Ik ben aan het werk. Facility management.'),
    (3, 'De Sheriff', 'Er is maar plaats voor één hoed in dit dorp.'),
    (4, 'De Kleine Verzamelaar', 'Dat is mijn snoep. En dat ook.'),
    (5, 'De Neus', 'Ik ruik een holo op tien meter.'),
    (7, 'De Monitor', 'Nog een spelletje? Iedereen? Top.'),
    (6, 'De Vierde Koning', 'Ik bracht geen goud. Ik bracht rizz.'),
    (8, 'El Tequila', 'Eén shot en ik sta in de kamer.'),
    (9, 'De Rode Lap', 'Rood is mijn kleur.', 'Rode Lap', 'Werkt als een stier op elke tegenstander.'),
  ]),
  ('Jakov', 'jakov', 'jakov', [
    (1, 'De Valpartij', 'Op mijn bek gegaan. Story gepost.'),
    (2, 'De Hoodie Goblin', 'Ik kom alleen \'s nachts buiten. Voor chips.'),
    (3, 'De Smirk', 'Ik heb gelijk. Ook als ik ongelijk heb.'),
    (4, 'De Stadiontong', 'Ik kwam voor de match. Zogezegd.'),
    (5, 'De Juniorprof', 'Mijn eerste sponsor was een boekhouder.'),
    (7, 'De Middenstip', 'Ik denk na. Over niks.'),
    (6, 'Het Pistebeest', 'Rondjes draaien is mijn cardio.'),
    (8, 'De Glitch', 'Dit is mijn echte gezicht. Vermoedelijk.'),
    (9, 'De Naakte Renner', 'Fiets: 2.000 euro. Kleren: 0 euro.', 'Velo-Schild', 'Blokkeert elke aanval met een achterwiel.'),
  ]),
  ('Jules', 'jules', 'jules', [
    (1, 'De BeReal', 'Het is 6u30. Het feest is nog bezig.'),
    (3, 'Cocktail Mood', 'Ik bestelde een cocktail, geen emmer.'),
    (4, 'De Close Talker', 'Hoi. Hoe gaat het? Van dichtbij?'),
    (5, 'De Kerstman', 'Hohoho. Waar is de bar?'),
    (6, 'De Chef', 'Pasta. Altijd pasta. Alleen pasta.'),
    (8, 'Lege Zakken', 'Kan jij deze week betalen?'),
    (2, 'De Kampioen', 'Heb ik al gezegd dat ik ooit een beker won?'),
    (7, 'Festival Fit', 'Luipaard is een neutrale kleur.'),
    (9, 'De Tuinsproeier', 'De haag moet ook water krijgen.', 'Tuinslang-Straal', 'Spoelt de tegenstander van het veld.'),
  ]),
  ('Luca', 'luca', 'luca', [
    (1, 'De Lollyman', 'Ik ben volwassen. Dit is mijn ontbijt.'),
    (3, 'Het Scheerschuim', 'Mijn ene baardhaar verdient respect.'),
    (6, 'Het Catalogusmodel', 'Mijn goede kant? Deze. Altijd deze.'),
    (7, 'Room Service', 'Twee pintjes voor jou, twee voor onderweg.'),
    (8, 'Te Laat', 'Ik was er gewoon. In gedachten.'),
    (9, 'De Rosé Rebel', 'Glazen zijn voor mensen met geduld.'),
    (4, 'De Achtergrondfiguur', 'Kijk naar mij. Niet achter mij.'),
    (5, 'De Prinses', 'Elke dag is mijn verjaardag.'),
    (2, 'De Zonnebloem', 'Een bloem zegt meer dan kleren.', 'Zonnebloem', 'Bloeit open en verblindt iedereen.'),
  ]),
  ('Seppe', 'seppe', 'seppe', [
    (1, 'De Denker', 'Ik denk na. Over frieten.'),
    (3, 'De Lampenkap', 'Ik ben het lichtpunt van de avond.'),
    (4, 'De Oerkreet', 'WORDLE IN ÉÉN KEER!'),
    (5, 'De Haarreclame', 'Het is natuurlijk. Bijna.'),
    (8, 'De Bubbels', 'Twee flessen. Eén voor mij. De andere ook.'),
    (9, 'De Pintjespout', 'Eerst de foto, dan drinken. Of omgekeerd.'),
    (6, 'De Lingerie Lord', 'Dresscode? Ik bén de dresscode.'),
    (7, 'Het LinkedInprofiel', 'Open to work. Vooral open to party.'),
    (2, 'De Fotograaf', 'Iemand moest de foto\'s nemen.', 'Kratje Kracht', 'Zit op zijn troon en laat de anderen het werk doen.'),
  ]),
  ('Stan Lavaert', 'stan-lavaert', 'stan_L', [
    (1, 'Het Flesje', 'Een glas? Waarom zou ik?'),
    (3, 'Het Hoofdwerk', 'Ik draag alles. Behalve verantwoordelijkheid.'),
    (4, 'De Kleine Supporter', 'Blauw-zwart sinds dag één.'),
    (7, 'Matchday', 'Ik supporter voor wie wint.'),
    (8, 'De Party Mouse', 'Minnie-oortjes, maximale energie.'),
    (9, 'Dinsdagproost', 'Proost. Het is dinsdag. Proost.'),
    (2, 'De Dark Knight', 'Ik ben de nacht. En ik ben weer te laat.'),
    (5, 'De Sniper', 'Mikken. Wachten. Missen. Opnieuw.'),
    (6, 'De Don', 'Ik zeg niet veel. Dat moet ook niet.', 'Sigarenrook', 'Hult het hele veld in mysterie.'),
  ]),
  ('Stan Sabbe', 'stan-sabbe', 'stan_S', [
    (1, 'De Fisheye', 'Smile! Ook als het waait.'),
    (3, 'De Onschuld', 'Ik? Ik heb niks gedaan.'),
    (4, 'Het Feestvarken', 'Nacht van mijn leven. Elke week.'),
    (5, 'De Close Call', 'Te dichtbij? Nooit van gehoord.'),
    (6, 'Het Festivalhoedje', 'Hoedje op, volume open.'),
    (8, 'De Brilmans', 'Ik zie alles. Ik onthou niks.'),
    (2, 'Maat XL', 'Maat S, shirt XL, ego XXL.'),
    (7, 'Het Kindermodel', 'Ik poseerde al voor ik kon praten.'),
    (9, 'De Klusjesman', 'Werkkledij is optioneel.', 'Boormachine', 'Boort dwars door elke verdediging.'),
  ]),
  ('Thibault', 'thibault', 'thibault', [
    (1, 'De Junglekoning', 'Dit is mijn bos. Tot de muggen komen.'),
    (3, 'De Campingstoel', 'Rust is ook een sport.'),
    (4, 'De Tong', 'Festivalmodus: aan.'),
    (5, 'De Pasfoto', 'Ik neem alles serieus. Behalve maandag.'),
    (6, 'De Verkeersgroet', 'Ik groet iedereen. Op mijn manier.'),
    (9, 'Duim Omhoog', 'Alles komt goed. Denk ik.'),
    (7, 'De Bar Baron', 'Ik bestel, jij betaalt.'),
    (8, 'Amerikaanse Rizz', 'Eén blik en ze is fan.'),
    (2, 'Midnight Streaker', 'Kleren vergeten. Pint niet.', 'Volle Maan', 'Licht de hele straat op. Iedereen kijkt weg.'),
  ]),
  ('Thomas', 'thomas', 'thomas', [
    (2, 'De Tweede Pint', 'Nog eentje? Ja, natuurlijk.'),
    (3, 'Paparazzi', 'Geen foto\'s. Behalve deze.'),
    (5, 'De Strandsprint', 'Naar de zee! Toch niet, te koud.'),
    (6, 'De Rallyrijder', 'Rijbewijs kwijt. Plan B.'),
    (8, 'De Stadstoerist', 'Cultuur snuiven, tong eruit.'),
    (9, 'Bedhead', 'Net opgestaan. Om vier uur \'s middags.'),
    (1, 'De Diva', 'Haar in een handdoek, frietjes op het vuur.'),
    (7, 'De Gele Trui', 'Ik won de Tour. In karton.'),
    (4, 'De Sneeuwschepper', 'Klaar voor de winter.', 'Sneeuwschep', 'Schept de tegenstander met één beweging van het veld.'),
  ]),
  ('Tuur', 'tuur', 'tuur', [
    (1, 'De Knuffelkoning', 'Ik won er geen. Ik kocht ze allemaal.'),
    (3, 'Blik van Staal', 'Eén blik. Iedereen stil.'),
    (4, 'Het Mondmasker', 'Kinbescherming is ook bescherming.'),
    (6, 'Het Blikje', 'Ademen kan later.'),
    (8, 'De Selfie', 'Mijn goede kant? Alle kanten.'),
    (9, 'De Snapchat', 'Gestuurd naar mijn crush. Alweer.'),
    (2, 'De Ober', 'Uw bestelling? Die is al op.'),
    (5, 'Het Langste Rietje', 'Afstand houden doe ik met stijl.'),
    (7, 'De Rizz Lord', 'Kwam met een bandana, vertrok met een kus.', 'Lippenstiftstempel', 'Markeert de tegenstander voor altijd.'),
  ]),
  ('Wout', 'wout', 'wout', [
    (2, 'De Zonnebril', 'Ik zie niks, maar ik zie er goed uit.'),
    (4, 'De Postkaart', 'Groetjes van zee. Het is koud.'),
    (5, 'Volle Maan', 'Mijn beste kant.'),
    (6, 'De Clubber', 'Zonnebril \'s nachts. Uit principe.'),
    (7, 'De Kaalkop', 'Nieuwe kapper, nieuwe ik.'),
    (8, 'Het Bakske', 'Waar ik zit, staat een bak.'),
    (1, 'Superbarman', 'Sneller tappen dan mijn schaduw.'),
    (3, 'De CEO', 'Ik heb een plan. Het plan is drinken.'),
    (9, 'De Tuinman', 'Tuinman van het jaar. Kruiwagen inbegrepen.', 'Kruiwagen-Charge', 'Rijdt dwars door de tegenstander.'),
  ]),
]

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
for person, slug, _map, kaarten in VRIENDEN:
    assert len(kaarten) == 9, person
    assert sorted(k[0] for k in kaarten) == list(range(1, 10)), person  # elke foto precies één keer
    for slot, k in enumerate(kaarten, 1):
        rarity = 'common' if slot <= 6 else 'epic' if slot <= 8 else 'legendary'
        hp, atk, df = stats(person + str(slot), rarity)
        sname = sdesc = spow = None
        if rarity == 'legendary':
            sname, sdesc, spow = k[3], k[4], roll(person + 'sp', 45, 55)
        rows.append((person, slot, k[1], rarity, hp, atk, df, f'cards/{slug}-{slot}.jpg', k[2], sname, sdesc, spow))
for i, (name, flavor) in enumerate(DETENTION, 1):
    hp, atk, df = stats('detention' + str(i), 'cat')
    rows.append(('Detention', i, name, 'cat', hp, atk, df, f'cards/detention-{i}.jpg', flavor, None, None, None))

lines = [f"  ({q(p)}, {s}, {q(n)}, {q(r)}, {hp}, {a}, {d}, {q(img)}, {q(f)}, {q(sn)}, {q(sd)}, {'null' if sp is None else sp})"
         for p, s, n, r, hp, a, d, img, f, sn, sd, sp in rows]
names = ', '.join(f"'{v[0]}'" for v in VRIENDEN)

sql = f"""-- =====================================================================
-- RIZZ ACADEMY: alle kaarten ({len(rows)} kaarten)
-- {len(VRIENDEN)} vrienden x 9 kaarten (slot 1-6 common, 7-8 epic, 9 legendary)
-- + 9 Detention-kaarten (troostkaarten, rarity 'cat').
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren: bestaande kaarten worden bijgewerkt, niet dubbel aangemaakt.
-- Afbeeldingen: cards/<naam>-<slot>.jpg (zonder afbeelding toont de site een varsity-letter).
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

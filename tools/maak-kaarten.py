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
    (1, 'Fisheye Arthuur', 'Kijkt recht in je ziel. En in je camera.'),
    (4, 'Stockfoto Arthuur', 'Stond ooit in een brochure. Niemand weet welke.'),
    (5, 'Nachtploeg Arthuur', 'Eén pintje. Het zevende.'),
    (6, 'Pruillip Arthuur', 'De drive-thru zei: de frietmachine is stuk.'),
    (7, 'Hawaii Hydratatie', 'Dorstig. Altijd. Overal.'),
    (8, 'Pokerface Arthuur', 'Hij weet iets. Hij zegt het niet.'),
    (2, 'Front Row Arthuur', 'Hij hoorde de drop. De drop hoorde hem ook.'),
    (3, 'Stella Sommelier', 'Proeft niet. Inhaleert.'),
    (9, 'Hedge of Fame Arthuur', 'Kalendermodel van juni, juli én augustus.', 'Schortje van Schaamte', 'Verblindt de tegenstander met pure zelfzekerheid.'),
  ]),
  ('Casper', 'casper', 'casper', [
    (3, 'Breaking News Casper', '"Ja mama, ik ben al wakker." Het is 15u.'),
    (4, 'Afterparty Casper', 'Laatste uit het café. Hij is de uitbater.'),
    (6, 'Mini-Hoedje Casper', 'Het hoedje is klein. Het ego niet.'),
    (7, 'Gym Bro Casper', 'Bulkseizoen. Het hele jaar door.'),
    (8, 'Veiligheid Eerst', 'Draagt een helm. Binnen. Je weet maar nooit.'),
    (9, 'Shock Value Casper', 'Zag net de rekening van zijn eigen café.'),
    (1, 'Summit Scream', 'Bereikte de top. Vertelde het aan de hele vallei.'),
    (5, 'Tinkerbell Casper', 'Strooit geen feeënstof. Strooit rondjes.'),
    (2, 'Hedge of Fame Casper', 'Huisdier niet inbegrepen.', 'Reismand-Defensie', 'Niemand weet wat erachter zit. Niemand wil het weten.'),
  ]),
  ('Gerben', 'gerben', 'gerben', [
    (1, 'Gerben in Shock', 'Zag net wat een holo Charizard kost.'),
    (2, 'Schuimparty Gerben', 'Wellness is ook facility management.'),
    (3, 'Zwarte Hoed Gerben', 'Kwam als cowboy. Vertrok als legende.'),
    (4, 'Mini Gerben', 'Al als kleuter een verzamelaar. Van snoep.'),
    (5, 'Neus voor Zaken', 'Ruikt een zeldzame kaart op tien meter.'),
    (7, 'Zomerkamp Gerben', 'Monitor van het jaar. Volgens zichzelf.'),
    (6, 'Kerststal Crasher', 'De vierde koning. Bracht geen goud, wel rizz.'),
    (8, 'El Tequila Gerben', 'Eén shot en hij staat in de kamer.'),
    (9, 'Hedge of Fame Gerben', 'Rood staat hem. Vooral strategisch.', 'Rode Lap', 'Werkt als een stier op elke tegenstander.'),
  ]),
  ('Jakov', 'jakov', 'jakov', [
    (1, 'Valpartij Jakov', 'Op zijn bek gegaan. Opgestaan. Snap gestuurd.'),
    (2, 'Hoodie Goblin', 'Komt enkel \'s nachts buiten. Voor chips.'),
    (3, 'Smirk Jakov', 'Weet dat hij gelijk heeft. Ook als dat niet zo is.'),
    (4, 'Stadion Jakov', 'Kwam voor de match. Bleef voor de camera.'),
    (5, 'Junior Wielrenner', 'Op zijn tiende al een sponsor: een boekhouder.'),
    (7, 'Middenstip Jakov', 'Denkt na over het leven. Op de middenstip.'),
    (6, 'Piste Beest', 'Rondjes draaien? Hij doet het professioneel.'),
    (8, 'Glitch Jakov', 'De camera heeft het opgegeven.'),
    (9, 'Hedge of Fame Jakov', 'Fiets: 2.000 euro. Kleren: 0 euro.', 'Velo-Schild', 'Blokkeert elke aanval met een achterwiel.'),
  ]),
  ('Jules', 'jules', 'jules', [
    (1, 'BeReal Jules', 'Dertien uur te laat. Nog steeds aan het feesten.'),
    (3, 'Cocktail Mood', 'Bestelde een cocktail. Kreeg een emmer.'),
    (4, 'Close Talker Jules', 'Persoonlijke ruimte? Nooit van gehoord.'),
    (5, 'Kerstfeest Jules', 'Hohoho. Ho. Ho. Hij is er nog.'),
    (6, 'Chef Jules', 'Kookt enkel pasta. Met volle overtuiging.'),
    (8, 'Blut Jules', 'Einde van de maand. Begin van de maand.'),
    (2, 'Kampioen Jules', 'Won ooit een beker. Praat er nog elke dag over.'),
    (7, 'Festival Fit', 'Luipaardprint. Fluoroze. Geen spijt.'),
    (9, 'Hedge of Fame Jules', 'Sproeit de haag. En zijn zelfvertrouwen.', 'Tuinslang-Straal', 'Spoelt de tegenstander van het veld.'),
  ]),
  ('Luca', 'luca', 'luca', [
    (1, 'Lolly Luca', 'Volwassen man. Gigantische lolly. Geen probleem.'),
    (3, 'Scheerschuim Luca', 'Heeft één baardhaar. Scheert het met liefde.'),
    (6, 'Catalogus Luca', 'Poseert voor een catalogus die niet bestaat.'),
    (7, 'Room Service Luca', 'Brengt pintjes rond. Drinkt er onderweg twee.'),
    (8, 'Te Laat Luca', 'Officieel genoteerd: te laat. Onofficieel: altijd.'),
    (9, 'Rosé Rebel', 'Een glas? Waarvoor?'),
    (4, 'Achtergrondfiguur', 'Kijk niet achter hem. Echt niet.'),
    (5, 'Prinses Luca', 'Birthday girl energy. 365 dagen per jaar.'),
    (2, 'Hedge of Fame Luca', 'Eén bloem. Eén schop. Nul spijt.', 'Zonnebloem', 'Bloeit open en verblindt iedereen.'),
  ]),
  ('Seppe', 'seppe', 'seppe', [
    (1, 'Denker Seppe', 'Diep in gedachten. Over frieten.'),
    (3, 'Lampenkap Seppe', 'Veiligheid boven alles. Ook binnen.'),
    (4, 'Oerkreet Seppe', 'Het geluid als de Wordle in één keer lukt.'),
    (5, 'Haarreclame Seppe', 'L\'Oréal belde. Hij had geen tijd.'),
    (8, 'Bubbels Seppe', 'Twee flessen. Eén voor hem. De andere ook.'),
    (9, 'Pintje Pout', 'Poseert. Drinkt. Herhaalt.'),
    (6, 'Lingerie Lord', 'Dresscode: verrassend.'),
    (7, 'LinkedIn Seppe', 'Open to work. Open to party.'),
    (2, 'Hedge of Fame Seppe', 'De enige die zijn kleren aanhield.', 'Kratje Kracht', 'Zit op zijn troon en laat de anderen het werk doen.'),
  ]),
  ('Stan Lavaert', 'stan-lavaert', 'stan_L', [
    (1, 'Stella Stan', 'Kalm. Koel. Geen glas nodig.'),
    (3, 'Hoofdwerk Stan', 'Draagt alles op zijn hoofd. Behalve verantwoordelijkheid.'),
    (4, 'Mini Stan', 'Al jong blauw-zwart. Al jong zelfzeker.'),
    (7, 'Matchday Stan', 'Supportert altijd. Voor wie, hangt af van de score.'),
    (8, 'Party Mouse Stan', 'Minnie-oortjes. Maximale energie.'),
    (9, 'Heineken Stan', 'Proost op alles. Ook op dinsdag.'),
    (2, 'Batstan', 'Niet de held die we nodig hebben. Wel die we verdienen.'),
    (5, 'Sniper Stan', 'Mikt. Wacht. Mist. Mikt opnieuw.'),
    (6, 'Don Stan', 'Hij zegt niet veel. Hij moet niet.', 'Sigarenrook', 'Hult het hele veld in mysterie.'),
  ]),
  ('Stan Sabbe', 'stan-sabbe', 'stan_S', [
    (1, 'Fisheye Stan S.', 'Lacht altijd. Zelfs met tegenwind.'),
    (3, 'Hoodie Stan S.', 'Kijkt onschuldig. Is het niet.'),
    (4, 'Feestvarken Stan S.', 'De nacht van zijn leven. Elke week.'),
    (5, 'Close Call Stan S.', 'Te dichtbij. Altijd te dichtbij.'),
    (6, 'Festival Stan S.', 'Hoedje op. Volume op.'),
    (8, 'Brilmans Stan S.', 'Ziet alles. Onthoudt niets.'),
    (2, 'XL Stan S.', 'Maat S. Shirt XL. Ego XXL.'),
    (7, 'Junior Model Stan S.', 'Poseerde als kind al als een topmodel.'),
    (9, 'Hedge of Fame Stan S.', 'Klusjesman van het jaar. Zonder werkkledij.', 'Boormachine', 'Boort dwars door elke verdediging.'),
  ]),
  ('Thibault', 'thibault', 'thibault', [
    (1, 'Jungle Thibault', 'Koning van het bos. Tot de mug kwam.'),
    (3, 'Campingstoel Kampioen', 'Rust is ook een sport.'),
    (4, 'Tong Thibault', 'Festivalmodus: geactiveerd.'),
    (5, 'Pasfoto Thibault', 'Neemt alles serieus. Behalve school.'),
    (6, 'Verkeersgroet Thibault', 'Groet iedereen op de weg. Op zijn manier.'),
    (9, 'Duim Omhoog Thibault', 'Alles komt goed. Hij heeft het niet nagekeken.'),
    (7, 'Bar Baron Thibault', 'Bestelt voor iedereen. Betaalt voor niemand.'),
    (8, 'Rizz Thibault', 'Rizzniveau: Amerikaans.'),
    (2, 'Midnight Streaker', 'Vergat zijn kleren. Niet zijn pint.', 'Volle Maan', 'Licht de hele straat op. Iedereen kijkt weg.'),
  ]),
  ('Thomas', 'thomas', 'thomas', [
    (2, 'Denker Thomas', 'Overweegt een tweede pint. Besluit: ja.'),
    (3, 'Paparazzi Thomas', 'Geen foto\'s alstublieft. Behalve deze.'),
    (5, 'Strandsprint Thomas', 'Rent naar de zee. Bedenkt zich.'),
    (6, 'Rally Thomas', 'Rijbewijs ingetrokken. Plan B.'),
    (8, 'Tong Uit Thomas', 'Stadsbezoek. Cultuur gesnoven.'),
    (9, 'Bedhead Thomas', 'Net opgestaan. Om 16u.'),
    (1, 'Diva Thomas', 'Haar in een handdoek. Frietjes op het vuur.'),
    (7, 'Gele Trui Thomas', 'Won de Tour. In karton.'),
    (4, 'Hedge of Fame Thomas', 'Klaar voor de winter. Niet voor de foto.', 'Sneeuwschep', 'Schept de tegenstander met één beweging van het veld.'),
  ]),
  ('Tuur', 'tuur', 'tuur', [
    (1, 'Knuffelkoning Tuur', 'Won geen enkele knuffel. Kocht ze allemaal.'),
    (3, 'Blik van Staal', 'Eén blik. Iedereen stil.'),
    (4, 'Mondmasker Tuur', 'Draagt zijn mondmasker als kinbeschermer.'),
    (6, 'Blikje Tuur', 'Hapt naar adem. Hapt naar Jupiler.'),
    (8, 'Selfie Tuur', 'Zijn goede kant? Alle kanten.'),
    (9, 'Snapchat Tuur', 'Stuurt deze foto naar zijn crush. Elke keer.'),
    (2, 'Ober Tuur', 'Serveert met stijl. Morst met stijl.'),
    (5, 'Rietje Tuur', 'Het langste rietje van het terras. Toevallig.'),
    (7, 'Rizz Lord Tuur', 'Kwam met een bandana. Vertrok met een kus.', 'Lippenstiftstempel', 'Markeert de tegenstander voor altijd.'),
  ]),
  ('Wout', 'wout', 'wout', [
    (2, 'Zonnebril Wout', 'Coolheid: maximaal. Zicht: minimaal.'),
    (4, 'Postkaart Wout', 'Groetjes van zee. Hij heeft het koud.'),
    (5, 'Volle Maan Wout', 'Toont zijn beste kant.'),
    (6, 'Clubbing Wout', 'Zonnebril \'s nachts. Uit principe.'),
    (7, 'Kaalkop Wout', 'Nieuwe kapper. Nieuwe start. Oude kater.'),
    (8, 'Bakske Wout', 'Zit op een bak. Zit nooit zonder bak.'),
    (1, 'Superbarman Wout', 'Tapt sneller dan zijn schaduw.'),
    (3, 'Business Wout', 'Heeft een plan. Het plan is drinken.'),
    (9, 'Hedge of Fame Wout', 'Tuinman van het jaar. Kruiwagen inbegrepen.', 'Kruiwagen-Charge', 'Rijdt dwars door de tegenstander.'),
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

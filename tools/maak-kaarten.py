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
    (1, 'The Lens', 'Too close? You\'re not close enough.'),
    (4, 'Stock Photo Guy', 'Licensed. Not for resale.'),
    (5, 'The Night Shift', 'Clocks in at midnight. Never clocks out.'),
    (6, 'The Stare-Down', 'Blinked first? You lose.'),
    (7, 'The Aloha Shirt', 'Out of office. Permanently.'),
    (8, 'Poker Face', 'You\'ll never know my hand.'),
    (2, 'Front Row', 'Loudest man in the building.'),
    (3, 'The Sommelier', 'I don\'t taste. I finish.'),
    (9, 'The Apron', 'Nothing to hide. Literally.', 'Apron Drop', 'Pure confidence. The opponent looks away first.'),
  ]),
  ('Casper', 'casper', 'casper', [
    (3, 'Breaking News', 'Woke up. Chose violence.'),
    (4, 'The Landlord', 'Last call is when I say so.'),
    (6, 'The Tiny Hat', 'Small hat. Big reputation.'),
    (7, 'The Gym Rat', 'Shirt optional. Gains mandatory.'),
    (8, 'Hard Hat', 'Safety first. Party second. Barely.'),
    (9, 'The Tab', 'Put it on my name. Everyone knows it.'),
    (1, 'King of the Hill', 'Climbed it. Owns it.'),
    (5, 'The Fairy Godfather', 'Grants wishes. Mostly rounds.'),
    (2, 'The Box', 'What\'s inside? Not your business.', 'Lockbox', 'Nobody knows what\'s in it. Nobody gets past it.'),
  ]),
  ('Gerben', 'gerben', 'gerben', [
    (1, 'The Miner', 'Digs deep. Finds holos.'),
    (2, 'Bubble Boss', 'Runs the place from the tub.'),
    (3, 'The Sheriff', 'New sheriff in town. Same old rules.'),
    (4, 'The Collector', 'Started young. Never stopped.'),
    (5, 'The Nose', 'Smells weakness from ten meters.'),
    (7, 'Camp Leader', 'Everybody follows. Nobody asks why.'),
    (6, 'The Wise Man', 'Came bearing gifts. Left with the room.'),
    (8, 'El Tequila', 'One shot. Zero regrets.'),
    (9, 'The Red Cape', 'Red means go.', 'Matador', 'Steps aside. The opponent charges into nothing.'),
  ]),
  ('Jakov', 'jakov', 'jakov', [
    (1, 'The Wipeout', 'Fell hard. Got up harder.'),
    (2, 'The Hood', 'Hood up. Talking down.'),
    (3, 'The Smirk', 'Already knows how this ends.'),
    (4, 'Stadium Mode', 'Ninety minutes. Zero chill.'),
    (5, 'The Rookie', 'Pro since day one.'),
    (7, 'Dead Center', 'Always in the middle of it.'),
    (6, 'Track Beast', 'Laps you. Twice.'),
    (8, 'The Glitch', 'Can\'t be patched.'),
    (9, 'The Bare Cyclist', 'Carbon frame. Zero clothes.', 'Wheel Shield', 'Blocks every attack with the back wheel.'),
  ]),
  ('Jules', 'jules', 'jules', [
    (1, 'The BeReal', '6:30 AM. Still standing.'),
    (3, 'Bucket List', 'Ordered a cocktail. Got a bucket. Finished it.'),
    (4, 'The Close Talker', 'Personal space is a suggestion.'),
    (5, 'The Elf', 'Delivers. Every season.'),
    (6, 'The Chef', 'Kitchen\'s closed. He\'s still cooking.'),
    (8, 'Empty Pockets', 'Rich in spirit. Broke in cash.'),
    (2, 'The Champion', 'Won once. Never forgot.'),
    (7, 'Festival Fit', 'Leopard print. Zero fear.'),
    (9, 'The Sprinkler', 'Waters the hedge. Drowns the competition.', 'Hose Blast', 'Washes the opponent off the field.'),
  ]),
  ('Luca', 'luca', 'luca', [
    (1, 'The Lollipop', 'Sweet on the outside.'),
    (3, 'The Shave', 'Clean cut. Sharp edge.'),
    (6, 'The Catalog Model', 'Only one angle. The right one.'),
    (7, 'Room Service', 'Two cold ones. Delivered.'),
    (8, 'Late Arrival', 'The party starts when I walk in.'),
    (9, 'The Rosé Rebel', 'Glasses are for amateurs.'),
    (4, 'Background Boss', 'Even in the back, he\'s the main character.'),
    (5, 'Birthday King', 'Every day is his day.'),
    (2, 'The Sunflower', 'Doesn\'t need clothes. Needs sunlight.', 'Bloom', 'Opens up and blinds the whole field.'),
  ]),
  ('Seppe', 'seppe', 'seppe', [
    (1, 'The Thinker', 'Already three moves ahead.'),
    (3, 'The Lampshade', 'Lights up every party.'),
    (4, 'The Battle Cry', 'Heard from three streets away.'),
    (5, 'The Flow', 'Hair this good is a full-time job.'),
    (8, 'The Bubbly', 'Two bottles. Both mine.'),
    (9, 'Cold One', 'Pose first. Drink after.'),
    (6, 'The Dress Code', 'Rules are for the guest list.'),
    (7, 'The CEO', 'Open to work. Closing deals.'),
    (2, 'The Photographer', 'Somebody had to take the pictures.', 'Crate Throne', 'Sits on his throne while others do the work.'),
  ]),
  ('Stan Lavaert', 'stan-lavaert', 'stan_L', [
    (1, 'Bottle Service', 'Glasses are for guests.'),
    (3, 'The Headliner', 'Carries the night. Every night.'),
    (4, 'Ultra Since Birth', 'Blue and black. No discussion.'),
    (7, 'Matchday', 'Ninety minutes of pure faith.'),
    (8, 'Party Ears', 'Ears on. Volume up.'),
    (9, 'Tuesday Toast', 'Any day is a reason.'),
    (2, 'The Dark Knight', 'Shows up when it gets dark.'),
    (5, 'The Sniper', 'One shot. One cup.'),
    (6, 'The Godfather', 'Doesn\'t say much. Doesn\'t have to.', 'Cigar Smoke', 'Wraps the whole field in mystery.'),
  ]),
  ('Stan Sabbe', 'stan-sabbe', 'stan_S', [
    (1, 'The Storm', 'Smiles through the hurricane.'),
    (3, 'Mr. Innocent', 'No witnesses. No case.'),
    (4, 'The Party Animal', 'Best night of his life. Weekly.'),
    (5, 'The Close Call', 'Too close is just close enough.'),
    (6, 'Festival Hat', 'Hat on. Brain off.'),
    (8, 'Four Eyes', 'Sees everything. Says nothing.'),
    (2, 'Size XL', 'Shirt XL. Ego XXL.'),
    (7, 'The Prodigy', 'Posing since before he could walk.'),
    (9, 'The Handyman', 'Work clothes not required.', 'Power Drill', 'Drills straight through any defense.'),
  ]),
  ('Thibault', 'thibault', 'thibault', [
    (1, 'King of the Jungle', 'His forest. His rules.'),
    (3, 'The Lawn Chair', 'Recovery is part of training.'),
    (4, 'The Tongue', 'Festival mode. No off switch.'),
    (5, 'The Mugshot', 'Unbothered. Unbreakable.'),
    (6, 'Road Rage', 'Waves at everyone. One finger.'),
    (9, 'Thumbs Up', 'Everything\'s under control. Probably.'),
    (7, 'The Bar Baron', 'He orders. You pay.'),
    (8, 'American Rizz', 'One look. Game over.'),
    (2, 'Midnight Streaker', 'Lost the clothes. Kept the beer.', 'Full Moon', 'Lights up the whole street. Everyone looks away.'),
  ]),
  ('Thomas', 'thomas', 'thomas', [
    (2, 'Round Two', 'Another one. Obviously.'),
    (3, 'Paparazzi', 'Always on camera. Never by accident.'),
    (5, 'The Sprint', 'First in the water. First out.'),
    (6, 'The Rally Driver', 'Brakes are optional.'),
    (8, 'The Tourist', 'Seen it. Tasted it. Next.'),
    (9, 'Bedhead', 'Rolled out of bed. Still won.'),
    (1, 'The Towel', 'Fresh out the shower. Still the main event.'),
    (7, 'The Yellow Jersey', 'Leads the pack. Always.'),
    (4, 'The Snow Plow', 'Clears the road. Clears the room.', 'Snow Shovel', 'Scoops the opponent off the field in one move.'),
  ]),
  ('Tuur', 'tuur', 'tuur', [
    (1, 'The Plushie King', 'Every claw machine fears him.'),
    (3, 'Steel Gaze', 'One look. Total silence.'),
    (4, 'The Chin Guard', 'Protection is protection.'),
    (6, 'Can Do', 'Finishes it in one breath.'),
    (8, 'The Selfie', 'No bad angles.'),
    (9, 'The Snapchat', 'Sent. Opened. No reply needed.'),
    (2, 'The Waiter', 'Your order? Already handled.'),
    (5, 'The Long Straw', 'Keeps his distance. Keeps his drink.'),
    (7, 'The Rizz Lord', 'Came with a bandana. Left with a kiss.', 'Lipstick Mark', 'Marks the opponent forever.'),
  ]),
  ('Wout', 'wout', 'wout', [
    (2, 'The Shades', 'Can\'t see a thing. Looks incredible.'),
    (4, 'The Postcard', 'Greetings from wherever he wants.'),
    (5, 'Full Moon', 'Shows his best side. Unasked.'),
    (6, 'The Clubber', 'Sunglasses at night. On principle.'),
    (7, 'The Buzz Cut', 'New cut. Same menace.'),
    (8, 'The Crate', 'Where he sits, the crate follows.'),
    (1, 'Top Shelf', 'Pours faster than you drink.'),
    (3, 'The Boss', 'Has a plan. The plan works.'),
    (9, 'The Gardener', 'Grows things. Breaks things.', 'Wheelbarrow Charge', 'Rolls straight through the opponent.'),
  ]),
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

lines = [f"  ({q(p)}, {s}, {q(n)}, {q(r)}, {hp}, {a}, {d}, {q(img)}, {q(f)}, {q(sn)}, {q(sd)}, {'null' if sp is None else sp})"
         for p, s, n, r, hp, a, d, img, f, sn, sd, sp in rows]
names = ', '.join(f"'{v[0]}'" for v in VRIENDEN)

sql = f"""-- =====================================================================
-- RIZZ ACADEMY: alle kaarten ({len(rows)} kaarten)
-- {len(VRIENDEN)} vrienden x 9 kaarten (slot 1-6 common, 7-8 epic, 9 legendary)
-- (Geen Detention-kaarten meer: wie de dagelijkse les niet haalt, krijgt een F.)
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

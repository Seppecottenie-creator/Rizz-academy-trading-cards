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
    (1, 'The Fisheye', 'I see everything. Mostly your nose.'),
    (4, 'Stock Photo Guy', 'Also available without watermark.'),
    (5, 'The Night Shift', 'One more and then I\'m going home. Promise.'),
    (6, 'The Pout', 'I\'m not mad. I\'m disappointed.'),
    (7, 'Mister Aloha', 'It\'s always vacation somewhere.'),
    (8, 'The Poker Face', 'I know nothing. I know everything.'),
    (2, 'Front Row', 'LOUDER! I CAN\'T HEAR YOU!'),
    (3, 'The Sommelier', 'Tasting is for amateurs.'),
    (9, 'The Apron', 'Calendar model: June through August.', 'Apron of Shame', 'Blinds the enemy with pure confidence.'),
  ]),
  ('Casper', 'casper', 'casper', [
    (3, 'Breaking News', 'Yes mom, I\'ve been awake for hours.'),
    (4, 'The Landlord', 'Last call? I decide when it\'s last call.'),
    (6, 'Tiny Hat Energy', 'Small hat. Big plans.'),
    (7, 'The Gym Bro', 'Never skips leg day. Always skips shirts.'),
    (8, 'Safety First', 'You never know when the ceiling attacks.'),
    (9, 'The Bar Tab', 'Who put all of this on MY tab?!'),
    (1, 'King of the Hill', 'I AM THE KING OF THIS MOUNTAIN!'),
    (5, 'Tinkerbell', 'I don\'t sprinkle fairy dust. I sprinkle rounds.'),
    (2, 'The Pet Carrier', 'What\'s in the box? None of your business.', 'Carrier Defense', 'Nobody knows what\'s behind it. Nobody wants to.'),
  ]),
  ('Gerben', 'gerben', 'gerben', [
    (1, 'The Miner', 'How much is that Charizard?!'),
    (2, 'Bubble Bath Boss', 'This counts as facility management.'),
    (3, 'The Sheriff', 'This town ain\'t big enough for two hats.'),
    (4, 'Lil\' Collector', 'That\'s my candy. And that one too.'),
    (5, 'The Nose', 'Smells a holo from ten meters away.'),
    (7, 'The Camp Counselor', 'One more game? Everyone? Great.'),
    (6, 'The Fourth Wise Man', 'Brought no gold. Brought rizz.'),
    (8, 'El Tequila', 'One shot and I walk into the room.'),
    (9, 'The Red Cape', 'Red is my color.', 'Red Cape', 'Works on every opponent like a bull.'),
  ]),
  ('Jakov', 'jakov', 'jakov', [
    (1, 'The Wipeout', 'Fell on my face. Posted the story.'),
    (2, 'Hoodie Goblin', 'Only comes out at night. For chips.'),
    (3, 'The Smirk', 'I\'m right. Even when I\'m wrong.'),
    (4, 'Stadium Tongue', 'I came for the match. Allegedly.'),
    (5, 'The Junior Pro', 'My first sponsor was an accountant.'),
    (7, 'The Center Spot', 'Thinking deeply. About nothing.'),
    (6, 'Track Beast', 'Riding in circles is my cardio.'),
    (8, 'The Glitch', 'This is my real face. Probably.'),
    (9, 'The Naked Cyclist', 'Bike: two grand. Clothes: zero.', 'Wheel Shield', 'Blocks every attack with a back wheel.'),
  ]),
  ('Jules', 'jules', 'jules', [
    (1, 'The BeReal', 'It\'s 6:30 AM. The party is still going.'),
    (3, 'Cocktail Mood', 'I ordered a cocktail, not a bucket.'),
    (4, 'The Close Talker', 'Hi. How are you? Up close?'),
    (5, 'Santa\'s Helper', 'Ho ho ho. Where\'s the bar?'),
    (6, 'The Chef', 'Pasta. Always pasta. Only pasta.'),
    (8, 'Empty Pockets', 'Can you get this one? And the next?'),
    (2, 'The Champion', 'Did I mention I once won a trophy?'),
    (7, 'Festival Fit', 'Leopard print is a neutral.'),
    (9, 'The Sprinkler', 'The hedge needs water too.', 'Hose Blast', 'Washes the opponent off the field.'),
  ]),
  ('Luca', 'luca', 'luca', [
    (1, 'The Lollipop Man', 'I\'m a grown man. This is breakfast.'),
    (3, 'Shaving Cream', 'My one beard hair deserves respect.'),
    (6, 'The Catalog Model', 'My good side? This one. Always this one.'),
    (7, 'Room Service', 'Two beers for you, two for the road.'),
    (8, 'Late Again', 'I was there. Spiritually.'),
    (9, 'The Rosé Rebel', 'Glasses are for patient people.'),
    (4, 'The Background Extra', 'Look at me. Not behind me.'),
    (5, 'The Princess', 'Every day is my birthday.'),
    (2, 'The Sunflower', 'One flower says more than clothes.', 'Sunflower', 'Blooms open and blinds everyone.'),
  ]),
  ('Seppe', 'seppe', 'seppe', [
    (1, 'The Thinker', 'Deep in thought. About fries.'),
    (3, 'The Lampshade', 'I am the highlight of the party.'),
    (4, 'The Battle Cry', 'WORDLE IN ONE!'),
    (5, 'The Shampoo Ad', 'It\'s natural. Almost.'),
    (8, 'The Bubbly', 'Two bottles. One for me. The other one too.'),
    (9, 'The Beer Pout', 'Pose first, drink later. Or the other way around.'),
    (6, 'The Lingerie Lord', 'Dress code? I AM the dress code.'),
    (7, 'The LinkedIn Profile', 'Open to work. Mostly open to party.'),
    (2, 'The Photographer', 'Somebody had to take the pictures.', 'Crate Power', 'Sits on his throne and lets others do the work.'),
  ]),
  ('Stan Lavaert', 'stan-lavaert', 'stan_L', [
    (1, 'Bottle Service', 'A glass? Why would I?'),
    (3, 'The Headliner', 'I carry everything. Except responsibility.'),
    (4, 'Lil\' Ultra', 'Blue and black since day one.'),
    (7, 'Matchday', 'I support whoever is winning.'),
    (8, 'Party Mouse', 'Mouse ears. Maximum energy.'),
    (9, 'Tuesday Cheers', 'Cheers. It\'s Tuesday. Cheers.'),
    (2, 'The Dark Knight', 'I am the night. And I\'m late again.'),
    (5, 'The Sniper', 'Aim. Wait. Miss. Repeat.'),
    (6, 'The Godfather', 'I don\'t say much. I don\'t have to.', 'Cigar Smoke', 'Wraps the whole field in mystery.'),
  ]),
  ('Stan Sabbe', 'stan-sabbe', 'stan_S', [
    (1, 'The Fisheye', 'Smile! Even in a hurricane.'),
    (3, 'Mr. Innocent', 'Me? I didn\'t do anything.'),
    (4, 'The Party Animal', 'Night of my life. Every week.'),
    (5, 'The Close Call', 'Too close? Never heard of it.'),
    (6, 'Festival Hat', 'Hat on. Volume up.'),
    (8, 'Four Eyes', 'I see everything. I remember nothing.'),
    (2, 'Size XL', 'Size S. Shirt XL. Ego XXL.'),
    (7, 'The Child Model', 'Posing since before I could talk.'),
    (9, 'The Handyman', 'Work clothes are optional.', 'Power Drill', 'Drills straight through any defense.'),
  ]),
  ('Thibault', 'thibault', 'thibault', [
    (1, 'King of the Jungle', 'This is my forest. Until the mosquitoes come.'),
    (3, 'The Lawn Chair', 'Resting is a sport too.'),
    (4, 'The Tongue', 'Festival mode: activated.'),
    (5, 'The Passport Photo', 'I take everything seriously. Except Mondays.'),
    (6, 'Road Rage', 'I greet everyone. In my own way.'),
    (9, 'Thumbs Up', 'Everything will be fine. Probably.'),
    (7, 'The Bar Baron', 'I order. You pay.'),
    (8, 'American Rizz', 'One look and she\'s a fan.'),
    (2, 'Midnight Streaker', 'Forgot his clothes. Not his beer.', 'Full Moon', 'Lights up the whole street. Everyone looks away.'),
  ]),
  ('Thomas', 'thomas', 'thomas', [
    (2, 'The Second Round', 'Another one? Obviously.'),
    (3, 'Paparazzi', 'No pictures please. Except this one.'),
    (5, 'The Beach Sprint', 'To the sea! Never mind, too cold.'),
    (6, 'The Rally Driver', 'License revoked. Plan B.'),
    (8, 'The Tourist', 'Absorbing culture. Tongue out.'),
    (9, 'Bedhead', 'Just woke up. At 4 PM.'),
    (1, 'The Diva', 'Towel on my head, fries on the stove.'),
    (7, 'The Yellow Jersey', 'I won the Tour. In cardboard.'),
    (4, 'The Snow Shoveler', 'Ready for winter.', 'Snow Shovel', 'Scoops the opponent off the field in one move.'),
  ]),
  ('Tuur', 'tuur', 'tuur', [
    (1, 'The Plushie King', 'Won none of them. Bought them all.'),
    (3, 'Steel Gaze', 'One look. Total silence.'),
    (4, 'The Chin Mask', 'Chin protection is still protection.'),
    (6, 'Can Do', 'Breathing can wait.'),
    (8, 'The Selfie', 'My good side? All of them.'),
    (9, 'The Snapchat', 'Sent to my crush. Again.'),
    (2, 'The Waiter', 'Your order? Already drank it.'),
    (5, 'The Longest Straw', 'Social distancing with style.'),
    (7, 'The Rizz Lord', 'Came with a bandana. Left with a kiss.', 'Lipstick Mark', 'Marks the opponent forever.'),
  ]),
  ('Wout', 'wout', 'wout', [
    (2, 'The Shades', 'I can\'t see a thing, but I look great.'),
    (4, 'The Postcard', 'Greetings from the beach. It\'s freezing.'),
    (5, 'Full Moon', 'My best side.'),
    (6, 'The Clubber', 'Sunglasses at night. On principle.'),
    (7, 'The Buzz Cut', 'New barber. New me.'),
    (8, 'The Crate', 'Wherever I sit, there\'s a crate.'),
    (1, 'Super Bartender', 'Pours faster than his shadow.'),
    (3, 'The CEO', 'I have a plan. The plan is drinking.'),
    (9, 'The Gardener', 'Gardener of the year. Wheelbarrow included.', 'Wheelbarrow Charge', 'Rolls straight through the opponent.'),
  ]),
]

# Troostkaarten (rarity 'cat'): wie de Wordle niet oplost, moet nablijven.
DETENTION = [
    ('Late for Class', 'The alarm went off. He didn\'t.'),
    ('Hangover of the Century', 'Never drinking again. Until Friday.'),
    ('Left on Read', 'She has "a boyfriend". Sure.'),
    ('Phone Confiscated', 'You\'ll get it back at the end of the year.'),
    ('Study Hall', 'Write 100 times: I will solve the Wordle.'),
    ('Lost at Beer Pong', 'All the cups. Every single one.'),
    ('Missed the Last Train', 'Sleeping on someone else\'s couch tonight.'),
    ('Rage Quit', 'The controller did not survive.'),
    ('Asleep in Lecture', 'Woke up in a different class.'),
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

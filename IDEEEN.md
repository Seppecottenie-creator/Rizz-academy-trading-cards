# Ideeën voor later

Lijst van ideeën die nog niet gebouwd zijn. Nieuwste bovenaan.

## 14 oktober 2026

### Boss fight (event van 1 uur) — uitgewerkt, nog niet bouwen
**Verloop**
- Het event staat vooraf gepland (door de admin, of vast bv. elke vrijdag 20u–21u).
- 24 uur vooraf verschijnt de boss op de campus met een countdown ("De Dean valt aan over 2u 14m"),
  plus een pushmelding bij de start.
- Tijdens dat uur doet iedereen zoveel mogelijk schade. Geen live HP-balk nodig: je ziet enkel je eigen
  schade en hoeveel aanvallen je nog hebt. Na het uur volgt de onthulling: is de boss verslagen of niet?
- Zakt de HP vroeger naar 0, dan is de boss meteen verslagen (wie later nog aanvalt, doet niet meer mee).

**Limieten (zodat het eerlijk blijft en je je collectie nodig hebt)**
- Max. **3 aanvallen** per speler per event.
- Elke aanval: een team van **3 kaarten**.
- Een kaart kan je **maar één keer per event** gebruiken → max. 9 verschillende kaarten.
  Wie een bredere collectie heeft, heeft dus een voordeel.

**Een aanval**
- Een kort gevecht van 5 rondes tegen de boss, met Flex / Roast / Charm zoals in The Arena.
- De boss geeft hints ("De Dean laadt iets op…") zodat goed kiezen meer schade oplevert: er zit skill in.
- Schade = kaartstats × vermenigvuldiger voor rarity × hoe goed je de rondes speelt.
- **Zwakte van de week**: bv. +50% schade met kaarten van één bepaalde persoon of één rarity
  (wordt bij de countdown bekendgemaakt, zodat je je teams kan plannen).
- Alles wordt op de server berekend (net als het casino), dus niet te manipuleren.

**HP van de boss**
- Groeit mee met de groep: bv. HP = vast bedrag × aantal spelers die de afgelopen 7 dagen actief waren.
  Zo moet ongeveer iedereen meedoen om te winnen.

**Beloningen**
- Boss verslagen: iedereen die meedeed krijgt credits naar verhouding van zijn schade + een gratis envelope.
- Top 3 schade: extra credits; nr. 1 krijgt een titel ("Dean Slayer") tot het volgende event.
- **Laatste klap**: wie de boss neerhaalt, krijgt een speciale trofee.
- Niet verslagen: een kleine troostprijs naar verhouding van je schade.
- Een (geheime) achievement voor bv. "3 aanvallen met enkel commons".

**Na afloop**
- Een uitslagenscherm: verslagen of niet, totale schade, ranking van iedereen, wie de laatste klap gaf.

### Inzetten op echte voetbalwedstrijden (casino)
- In het casino een "Sportsbook": de komende wedstrijden (bv. Jupiler Pro League, Champions League, Rode Duivels).
- Inzetten met credits op 1 / X / 2 (thuis wint, gelijk, uit wint); later eventueel exacte score of "beide teams scoren".
- Quoteringen: vast per wedstrijd bij het openen (bv. uit een gratis voetbal-API, of eenvoudig zelf berekend),
  met een kleine marge voor het casino zoals bij de andere spelletjes.
- Inzetten sluiten bij de aftrap. Na de wedstrijd haalt de server automatisch de uitslag op en betaalt uit.
- Technisch: een gratis voetbal-API (bv. football-data.org) via een Supabase Edge Function + een uurlijkse taak
  (pg_cron, zoals de meldingen). De API-sleutel blijft in Supabase, nooit in de site.
- Extra: een klassement "beste voorspeller" van de week, en een pushmelding als je inzet gewonnen is.
- Enkel met credits uit het spel, nooit met echt geld.

### Achtergrondmuziek en geluidseffecten
- Rustige achtergrondmuziek per plek (campus, casino, The Arena, Food Truck), dag en nacht anders.
- Geluidseffecten: envelope openen, zeldzame kaart (extra groot bij legendary), kaarten delen bij blackjack,
  slotmachine, roulettebal, paardenrace, munten bij winst, pintje leegdrinken, klappen in The Arena.
- Een knop om muziek en geluid apart aan/uit te zetten (standaard muziek uit, geluid aan); onthouden per toestel.
- Opgelet: browsers spelen pas geluid af na de eerste tik op de pagina; bestanden klein houden voor de gsm.

### Rizz quiz
- Vragen over de groep zelf ("Wie zei ooit…", "Wie heeft de meeste…"), of over elkaars kaarten.
- Eventueel als dagelijkse quiz of als duel tegen een vriend.
- Vragen kunnen door spelers zelf ingediend worden (via Town Hall).

### Battle pass
- Seizoen van bv. 4 weken met niveaus; XP door examens, battles, casino, quiz.
- Gratis spoor en "premium" spoor (te kopen met credits).
- Beloningen: credits, envelopes, en cosmetica: kaartranden, profielkaders, titels onder je naam,
  kamerthema's voor het Frat House, emotes, een andere kaartachterkant.

### Geheime achievements
- Trofeeën die je pas ziet als je ze haalt (bv. "3 keer na elkaar bust", "om 3u 's nachts een examen spelen",
  "10 pintjes op één dag", "verliezen met een legendary").
- In de lijst enkel een "???"-vakje, zodat mensen gaan zoeken.

### Meer in de Food Truck
- Naast pintjes: shotjes, kapsalon, en andere (fictieve) middelen.
- Elk met een eigen effect en animatie; combinaties kunnen zeldzame dingen unlocken
  (geheime achievement, speciale kaartrand, een verborgen kaart…).

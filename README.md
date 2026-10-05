# Rizz Academy Trading Cards

Verzamelkaarten-site voor de vriendengroep. Je start op een campuskaart met een gebouw per onderdeel:
Exam Hall (lessenrooster: elke dag een ander vak met een minigame, ma Wordle · di Math · wo basketbal · do History · vr darts · za beer pong · zo pour the pint; je score wordt een cijfer A-F, een F = geen kaart), Frat House (een kamer per persoon: zijn 9 kaarten uit jouw collectie
in houten kaders, plus de trofeeën van de bewoner), The Arena (battles in rondes: Flex / Roast / Charm),
Black Market (ruilen), The Vault (shop), The Library (stats) en Town Hall (ideeën).
- `img/`: de foto's van de campus, het Frat House en de kamer (gemaakt met AI, geen echte personen).

- `index.html`: de volledige site (HTML + CSS + JavaScript), gehost op GitHub Pages.
- `words.txt`: geldige gokwoorden voor de Wordle.
- `cards/`: kaartafbeeldingen, met exact de naam uit `image_url` (bv. `cards/thomas-1.jpg`).
  Zolang een afbeelding ontbreekt, toont de kaart een varsity-letter.
- `supabase/setup.sql`: de volledige database voor een nieuw, leeg Supabase-project.
- `supabase/update-*.sql`: wijzigingen voor een bestaand project, in volgorde uitvoeren.
- `supabase/kaarten.sql`: alle kaarten (gegenereerd door `tools/maak-kaarten.py`).

SQL uitvoeren: Supabase → SQL Editor → nieuwe query → het volledige bestand plakken → Run →
kies "Run without RLS" (de scripts zetten RLS zelf aan). Alle scripts mogen opnieuw uitgevoerd worden.

**Op gsm** werkt de site als app: wie ze in Safari/Chrome opent, krijgt eerst de uitleg om ze op het beginscherm
te zetten (`manifest.webmanifest`, `sw.js`, iconen in `img/`). In de app speel je liggend (Android draait vanzelf,
op iPhone verschijnt "Draai je gsm"). Noodsleutel om toch in de browser te werken: voeg `?browser=1` toe aan de link
(`?browser=0` zet het terug).

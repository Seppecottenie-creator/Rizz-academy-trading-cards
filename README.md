# Rizz Academy Trading Cards

Verzamelkaarten-site voor de vriendengroep: elke dag een Wordle, pakjes openen,
kaarten verzamelen in je yearbook, ruilen, battles en een shop.

- `index.html`: de volledige site (HTML + CSS + JavaScript), gehost op GitHub Pages.
- `words.txt`: geldige gokwoorden voor de Wordle.
- `cards/`: kaartafbeeldingen, met exact de naam uit `image_url` (bv. `cards/thomas-1.jpg`).
  Zolang een afbeelding ontbreekt, toont de kaart een varsity-letter.
- `supabase/setup.sql`: de volledige database voor een nieuw, leeg Supabase-project.
- `supabase/update-*.sql`: wijzigingen voor een bestaand project, in volgorde uitvoeren.
- `supabase/kaarten.sql`: alle kaarten (gegenereerd door `tools/maak-kaarten.py`).

SQL uitvoeren: Supabase → SQL Editor → nieuwe query → het volledige bestand plakken → Run →
kies "Run without RLS" (de scripts zetten RLS zelf aan). Alle scripts mogen opnieuw uitgevoerd worden.

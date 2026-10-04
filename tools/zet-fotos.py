# Zet de aangeleverde foto's klaar als kaartafbeeldingen: cards/<bestandsnaam>-<slot>.jpg
# Gebruik: python3 tools/zet-fotos.py <map met per vriend een submap>
#   bv. python3 tools/zet-fotos.py ~/fotos   (met ~/fotos/seppe/, ~/fotos/stan_L/, ...)
# De foto's worden per submap op bestandsnaam gesorteerd en genummerd (1-9), zoals in
# tools/maak-kaarten.py. Ze worden gedraaid volgens de EXIF-info, verkleind tot max.
# 900 px en als JPEG opgeslagen. Vereist ImageMagick (convert).
import importlib.util, pathlib, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('kaarten', ROOT / 'tools' / 'maak-kaarten.py')
# maak-kaarten.py schrijft bij het laden ook kaarten.sql opnieuw; dat is onschuldig.
kaarten = importlib.util.module_from_spec(spec); spec.loader.exec_module(kaarten)

bron = pathlib.Path(sys.argv[1]).expanduser()
for person, slug, mapnaam, lijst in kaarten.VRIENDEN:
    fotos = sorted(p for p in (bron / mapnaam).rglob('*') if p.suffix.lower() in ('.jpg', '.jpeg', '.png'))
    if len(fotos) != 9:
        print(f'{person}: {len(fotos)} foto\'s gevonden in {bron / mapnaam}, overgeslagen'); continue
    for slot, k in enumerate(lijst, 1):
        doel = ROOT / 'cards' / f'{slug}-{slot}.jpg'
        subprocess.run(['convert', str(fotos[k[0] - 1]), '-auto-orient', '-strip', '-resize', '900x900>',
                        '-quality', '82', str(doel)], check=True)
    print(f'{person}: 9 foto\'s klaargezet')

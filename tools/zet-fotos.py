# Zet de aangeleverde foto's klaar als kaartafbeeldingen: <uitvoermap>/<bestandsnaam>-<slot>.jpg
# Gebruik: python3 tools/zet-fotos.py <map met per vriend een submap> <uitvoermap>
#   bv. python3 tools/zet-fotos.py ~/fotos ~/kaartfotos
# De foto's worden per submap op bestandsnaam gesorteerd en genummerd (1-9), zoals in
# tools/maak-kaarten.py. Elke foto wordt bijgesneden tot 4:5 (het fotovenster op de kaart)
# met zo veel mogelijk van de foto, verschoven zodat het gezicht er altijd in valt.
# Vereist: pip install opencv-python-headless + het YuNet-model naast dit script (zie MODEL)
# De uitvoer hoort NIET in de repo (die is openbaar): upload ze naar Supabase Storage.
import importlib.util, pathlib, sys
import cv2

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('kaarten', ROOT / 'tools' / 'maak-kaarten.py')
kaarten = importlib.util.module_from_spec(spec); spec.loader.exec_module(kaarten)

RATIO = 4 / 5          # breedte / hoogte van het fotovenster
OUT_W = 800            # uitvoerbreedte in pixels

# Handmatige correcties: (map, fotonummer) -> (x, y, zoom): middelpunt als fractie van de foto,
# zoom < 1 snijdt kleiner uit (enkel waar nodig).
FOCUS = {
    ('luca', 8): (0.5, 0.40, 0.8),   # schermfoto: inzoomen zodat de naam van een medeleerling wegvalt
}

# YuNet-gezichtsdetector (vindt ook gezichten met bril of onder een hoek). Download het model:
# https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet
MODEL = pathlib.Path(__file__).resolve().parent / 'face_detection_yunet_2023mar.onnx'

def find_face(img):
    h, w = img.shape[:2]
    scale = min(1, 1280 / max(h, w))
    small = cv2.resize(img, (int(w * scale), int(h * scale))) if scale < 1 else img
    det = cv2.FaceDetectorYN.create(str(MODEL), '', (small.shape[1], small.shape[0]), 0.6)
    _, faces = det.detect(small)
    if faces is None or not len(faces): return None
    x, y, fw, fh = max(faces, key=lambda f: f[2] * f[3] * f[14])[:4] / scale
    return (x + fw / 2) / w, (y + fh / 2) / h, fw / w

def crop(img, focus, zoom=None):
    """Grootst mogelijke 4:5-uitsnede (zo veel mogelijk van de foto), enkel verschoven zodat
    het gezicht erin valt. Inzoomen gebeurt alleen met een expliciete zoom (zie FOCUS)."""
    h, w = img.shape[:2]
    cw, ch = (w, w / RATIO) if w / h < RATIO else (h * RATIO, h)
    if zoom: cw, ch = cw * zoom, ch * zoom
    cx, cy = (focus[0] * w, focus[1] * h) if focus else (w / 2, h / 2)
    x0 = min(max(cx - cw / 2, 0), w - cw); y0 = min(max(cy - ch / 2, 0), h - ch)
    out = img[int(y0):int(y0 + ch), int(x0):int(x0 + cw)]
    return cv2.resize(out, (OUT_W, int(OUT_W / RATIO)), interpolation=cv2.INTER_AREA)

if __name__ == '__main__':
    bron, doelmap = pathlib.Path(sys.argv[1]).expanduser(), pathlib.Path(sys.argv[2]).expanduser()
    doelmap.mkdir(parents=True, exist_ok=True)
    for person, slug, mapnaam, lijst in kaarten.VRIENDEN:
        fotos = sorted(p for p in (bron / mapnaam).rglob('*') if p.suffix.lower() in ('.jpg', '.jpeg', '.png'))
        if len(fotos) != 9:
            print(f"{person}: {len(fotos)} foto's gevonden, overgeslagen"); continue
        for slot, k in enumerate(lijst, 1):
            img = cv2.imread(str(fotos[k[0] - 1]))  # OpenCV past de EXIF-oriëntatie zelf toe
            manual = FOCUS.get((mapnaam, k[0]))
            focus = manual or find_face(img)
            cv2.imwrite(str(doelmap / f'{slug}-{slot}.jpg'), crop(img, focus, manual and manual[2]), [cv2.IMWRITE_JPEG_QUALITY, 84])
            print(f"{slug}-{slot}: {'gezicht' if focus else 'GEEN GEZICHT'} (foto {k[0]})")

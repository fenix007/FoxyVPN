# FoxyVPN app icon

The shared source artwork is `foxy-superhero.png`, generated with GPT Image 2
through Airouter using the imagegen CLI fallback. It is a square PNG
(1024 × 1024 recommended, minimum 512 × 512). The generation prompt is kept in
`foxy-superhero.prompt.txt`. Do not replace the source with a placeholder.

After saving a new source PNG, prepare Windows and Android images on Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/prepare-branding.ps1
```

This uses Windows System.Drawing without third-party image packages. It writes
`foxy-superhero-desktop.png`, a 1024 × 1024 transparent canvas with the complete
square artwork fitted into a centered 896 × 896 rounded tile (180 px corner
radius). Fourfold supersampling smooths the alpha boundary; only the tile's
background corners are clipped, without extracting or repainting the fox.
The original source stays unchanged. It then creates
`windows/FoxyVPN/Assets/FoxyVPN.ico` from that desktop PNG with 16, 24, 32, 48,
64, 128 and 256 px frames,
and `app/src/main/res/drawable-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher_superhero.png`.
Android uses the image as an opaque adaptive background with a transparent
foreground. The full artwork occupies the central 72 dp on a 108 dp canvas;
the outer 18 dp on each side extend its edge rows and columns, and corner pixels
fill the corners. Launcher masks and parallax reveal a continuous background
instead of rectangular transparent edges. The original vector resources remain
in `drawable/`.

Android backgrounds continue to use the original square source. Commit both
PNGs and the generated Windows/Android resources together.
They are ordinary build inputs; Android and cross-platform Windows builds do
not need the conversion script or System.Drawing installed.

On macOS, `macos/scripts/build-app.sh` automatically runs
`bash macos/scripts/prepare-branding.sh` using the built-in `sips` and `iconutil`.
It reads the committed `foxy-superhero-desktop.png`, creates
`macos/.build/branding/FoxyVPN.icns` and adds it to the app before code signing.
`package-app.sh` includes the result in the DMG.

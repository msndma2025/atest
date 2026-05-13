# NIRRP Infrastructure Portal — GeoServer → Vector Tiles Migration

## What This Solves

The portal currently loads buildings per district by fetching a GeoServer WFS URL.
GeoServer sends every polygon at once. For large districts Chrome runs out of memory
and crashes. This guide replaces GeoServer WFS with a vector tile server that only
sends the tiles visible in the current viewport — memory stays flat no matter how
many buildings exist.

```
BEFORE (crashes):
  Browser → GeoServer WFS → all polygons in one response (200–500 MB) → Chrome OOM

AFTER (works):
  Browser → tileserver-gl → only visible tiles ({z}/{x}/{y}.pbf, ~50–500 KB total)
```

---

## Architecture

```
HPC  (172.18.1.174)
├── WSL Ubuntu
│   └── convert.sh  ← runs once, produces buildings.mbtiles
└── Windows CMD
    └── tileserver-gl-light  ← always running, port 3000
        └── http://172.18.1.174:3000/data/buildings/{z}/{x}/{y}.pbf

Client PC  (your official machine — limited storage, no data files)
└── infra_portal  (React + Vite app)
    ├── MapContainer.jsx  ← changed: WFS fetch → vector tile source
    ├── buildingData.js   ← no longer used for WFS; kept for district name lookup
    ├── pybackend/app.py  ← changed: reads shapefiles from HPC disk, not GeoServer
    └── .env              ← TILE_SERVER_URL added, GEOSERVER_URL kept for reference
```

---

## Part 1 — HPC Setup

### 1.1 Prerequisites (WSL Ubuntu — one time)

Open WSL:
```
Windows key → type "Ubuntu" → open terminal
```

Install GDAL:
```bash
sudo apt update && sudo apt install -y gdal-bin python3
ogr2ogr --version      # confirm: GDAL 3.x.x
```

Install tippecanoe (Linux only — this is why WSL is needed):
```bash
sudo apt install -y build-essential libsqlite3-dev zlib1g-dev
git clone https://github.com/felt/tippecanoe.git
cd tippecanoe
make -j$(nproc)
sudo make install
tippecanoe --version   # confirm: tippecanoe v2.x.x
cd ~
```

Or if brew is already set up in your WSL:
```bash
brew install tippecanoe
```

### 1.2 Check your height column name

Before running the conversion, confirm the exact column name in your shapefiles:
```bash
ogrinfo -al -so "/mnt/c/HPC/buildings/Abbottabad_buildings.shp"
```

Look in the output for something like `height (Real)` or `Height (Real)` or
`floors (Integer)`. Whatever it says, that exact string goes into `HEIGHT_COLUMN`
in `convert.sh`.

### 1.3 Edit convert.sh

Open `convert.sh` and set the three variables at the top:

```bash
BUILDINGS_DIR="/mnt/c/HPC/buildings"   # folder with all *_buildings.shp files
OUTPUT_DIR="/mnt/c/HPC/tiles"          # where buildings.mbtiles will be written
HEIGHT_COLUMN="height"                  # exact column name from ogrinfo above
```

Windows → WSL path conversion:
```
C:\HPC\buildings  →  /mnt/c/HPC/buildings
D:\data\shp       →  /mnt/d/data/shp
```

### 1.4 Run the conversion (WSL)

```bash
bash /path/to/convert.sh
```

The script processes each district independently:
1. Convert `Mardan_buildings.shp` → `Mardan_buildings.geojson` (WGS84, missing .shx handled)
2. Add `height` and `base_height` fields
3. Run tippecanoe → `Mardan_buildings.mbtiles`
4. Delete `Mardan_buildings.geojson`
5. Repeat for every other `*_buildings.shp` in the folder

Output — one MBTiles per district:
```
C:\HPC\tiles\Mardan_buildings.mbtiles
C:\HPC\tiles\Nowshera_buildings.mbtiles
C:\HPC\tiles\Karachi_buildings.mbtiles
```

Approximate time on your HPC (196 cores, NVMe):

| Total buildings | Approx. time |
|---|---|
| 500,000 | 1–2 min |
| 5,000,000 | 5–10 min |
| 50,000,000 | 30–60 min |

### 1.5 Prerequisites — Windows CMD (one time)

Install Node.js from https://nodejs.org (LTS). Then in Windows CMD:
```cmd
npm install -g tileserver-gl-light
tileserver-gl-light --version
```

That is all. No Java, no GeoServer, no GDAL on Windows side.

### 1.6 Start the tile server (Windows CMD)

Point tileserver-gl-light at the **folder** — it picks up every `.mbtiles` file
inside automatically:

```cmd
tileserver-gl-light --mbtiles C:\HPC\tiles --port 3000
```

Verify it works — open a browser on the HPC and visit:
```
http://localhost:3000/data/Abbottabad_buildings.json
```

You should see JSON with `"tiles": ["http://...3000/data/Abbottabad_buildings/{z}/{x}/{y}.pbf"]`.
Every district gets its own endpoint at the same pattern.

### 1.7 Open Windows Firewall for port 3000

In Windows CMD (run as Administrator):
```cmd
netsh advfirewall firewall add rule name="TileServer3000" dir=in action=allow protocol=TCP localport=3000
```

Test from your client PC's browser:
```
http://172.18.1.174:3000/data/buildings.json
```

### 1.8 Keep the tile server running (optional — no CMD window)

```cmd
npm install -g pm2
pm2 start "tileserver-gl-light C:\HPC\tiles\buildings.mbtiles --port 3000" --name tiles
pm2 save
pm2 startup windowsservice
```

---

## Part 2 — Client PC (infra_portal changes)

The client PC stores no data files. Everything is fetched from the HPC.
Make these four changes to the infra_portal repo.

### 2.1 .env

Add one line — the tile server URL. Keep `GEOSERVER_URL` in case you still need
WMS for other layers:

```bash
# existing
GEOSERVER_URL=http://172.18.1.151:8080

# add this
TILE_SERVER_URL=http://172.18.1.174:3000
```

### 2.2 client/src/utils/buildingData.js

Replace the file. Instead of mapping districts to WFS URLs it now maps them to
their own per-district tile URL — same naming pattern as the MBTiles files:

```js
// buildingData.js
// Each district has its own MBTiles file served by tileserver-gl.
// URL pattern: http://HPC:3000/data/<District>_buildings/{z}/{x}/{y}.pbf

const TILE_SERVER = import.meta.env.VITE_TILE_SERVER_URL
  || 'http://172.18.1.174:3000';

export function buildingTileUrl(districtKey) {
  // districtKey = "Abbottabad" → "Abbottabad_buildings"
  return `${TILE_SERVER}/data/${districtKey}_buildings/{z}/{x}/{y}.pbf`;
}

let _buildingIndex = null;

export async function loadBuildingIndex() {
  if (_buildingIndex) return _buildingIndex;
  const res  = await fetch('/geoserver_upload_tracker.csv');
  const text = await res.text();
  const lines = text.trim().split('\n');
  const header = lines[0].split(',');
  const sfIdx  = header.indexOf('shapefile_name');

  const index = {};
  for (let i = 1; i < lines.length; i++) {
    const cols = lines[i].split(',');
    const shp  = (cols[sfIdx] || '').trim();
    if (!shp) continue;
    const districtKey = shp.replace(/_buildings\.shp$/i, '');  // "Abbottabad"
    index[districtKey.toLowerCase()] = { districtKey };
  }
  _buildingIndex = index;
  return index;
}

export function findBuildingEntry(buildingIndex, districtName) {
  if (!buildingIndex || !districtName) return null;
  return buildingIndex[districtName.toLowerCase().trim()] || null;
}
```

Add to `vite.config.js` inside `defineConfig → define`:
```js
'import.meta.env.VITE_TILE_SERVER_URL': JSON.stringify(process.env.TILE_SERVER_URL || ''),
```

### 2.3 client/src/components/Map/MapContainer.jsx

**What to remove:**
- The `useEffect` (lines ~394–455) that fetches `activeBuildingDistrict.wfsUrl`,
  adds a `geojson` source, and adds `district-buildings-fill` / `district-buildings-line`
  / `district-buildings-3d` layers.
- `buildingFetchRef` and `activeBuildingRef` refs.

**What to add:**

Import at the top:
```js
import { buildingTileUrl } from '../../utils/buildingData';
```

Replace the WFS `useEffect` with this — it swaps the vector tile source each time
a different district is selected:

```js
useEffect(() => {
  const map = mapRef.current;
  if (!map || !mapLoaded) return;

  // Remove previous district layers and source
  ['district-buildings-3d', 'district-buildings-line', 'district-buildings-fill']
    .forEach((id) => { if (map.getLayer(id)) map.removeLayer(id); });
  if (map.getSource('district-buildings-src')) map.removeSource('district-buildings-src');

  if (!activeBuildingDistrict?.districtKey || !showBuildings) return;

  const { districtKey } = activeBuildingDistrict;

  // Load this district's own MBTiles as a vector tile source
  map.addSource('district-buildings-src', {
    type: 'vector',
    tiles: [buildingTileUrl(districtKey)],   // e.g. .../Abbottabad_buildings/{z}/{x}/{y}.pbf
    minzoom: 4,
    maxzoom: 16,
  });

  map.addLayer({
    id: 'district-buildings-3d',
    type: 'fill-extrusion',
    source: 'district-buildings-src',
    'source-layer': 'buildings',   // must match LAYER_NAME in convert.sh
    paint: {
      'fill-extrusion-color': [
        'interpolate', ['linear'], ['get', 'height'],
         0,  '#1a237e',
         5,  '#1565c0',
        10,  '#0277bd',
        20,  '#00838f',
        35,  '#2e7d32',
        60,  '#f9a825',
       100,  '#e65100',
      ],
      'fill-extrusion-height':  ['get', 'height'],
      'fill-extrusion-base':    ['get', 'base_height'],
      'fill-extrusion-opacity': 0.85,
    },
  });

  map.addLayer({
    id: 'district-buildings-line',
    type: 'line',
    source: 'district-buildings-src',
    'source-layer': 'buildings',
    paint: {
      'line-color': 'rgba(255,255,255,0.15)',
      'line-width': 0.4,
    },
  });

  // Zoom to district
  if (districtsGeoJSON) {
    const feat = districtsGeoJSON.features.find(
      (f) => f.properties.name?.toLowerCase() === districtKey.toLowerCase()
    );
    if (feat) {
      const bbox = getBbox([feat]);
      map.fitBounds(bbox, { padding: 60, pitch: 45, duration: 800 });
    }
  }
}, [activeBuildingDistrict, showBuildings, mapLoaded]);
```

In `Sidebar.jsx` where `activeBuildingDistrict` is assembled, pass only `districtKey`:
```js
// Before
onDistrictSelect({ districtKey: entry.districtKey, wfsUrl: entry.wfsUrl, qualifiedName: entry.qualifiedName });

// After
onDistrictSelect({ districtKey: entry.districtKey });
```

### 2.4 pybackend/app.py

The Python backend currently downloads a shapefile ZIP from GeoServer WFS, extracts
it, then runs GeoPandas spatial analysis. Replace the download logic — the shapefiles
already exist on the HPC disk. Python reads them directly, no GeoServer needed.

**Replace the `GEOSERVER_BASE`, `WORKSPACE`, `TEMP_DIR` block and the entire
`_download_worker` / `/pyapi/buildings/download` / `/pyapi/buildings/progress` /
`/pyapi/buildings/status` / `/pyapi/buildings/cleanup` endpoints with this:**

```python
import os, json, glob
import geopandas as gpd
import pandas as pd
from flask import Flask, Response, jsonify, request
from flask_cors import CORS
from shapely.geometry import shape

app = Flask(__name__)
CORS(app)

# ── Configuration ─────────────────────────────────────────────────────────────
# Path to the folder holding all *_buildings.shp files on the HPC.
# Edit this to match your actual path.
BUILDINGS_DIR = os.environ.get(
    "BUILDINGS_DIR",
    r"C:\HPC\buildings"           # Windows path — Python on Windows reads this fine
)

# Flood susceptibility GeoJSON (already on disk, shared with client)
SUS_GEOJSON = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "client", "public", "flood", "Flood_Sus.geojson",
)

ENCROACHMENT_GEOJSON = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "client", "public", "encroachment_geom.geojson",
)
# ─────────────────────────────────────────────────────────────────────────────

def _shapefile_path(district: str) -> str:
    """Return the full path to a district's shapefile, case-insensitive match."""
    pattern = os.path.join(BUILDINGS_DIR, f"*_buildings.shp")
    for path in glob.glob(pattern):
        stem = os.path.basename(path).replace("_buildings.shp", "")
        if stem.lower() == district.lower():
            return path
    return None


def _load_district(district: str) -> gpd.GeoDataFrame:
    """Read a district shapefile into a GeoDataFrame in WGS84."""
    path = _shapefile_path(district)
    if not path:
        raise FileNotFoundError(f"No shapefile found for district: {district}")
    gdf = gpd.read_file(path)
    if gdf.crs and gdf.crs.to_epsg() != 4326:
        gdf = gdf.to_crs(epsg=4326)
    return gdf


@app.route("/pyapi/health")
def health():
    return jsonify(status="ok")


# ── Building count ─────────────────────────────────────────────────────────────
@app.route("/pyapi/buildings/count")
def building_count():
    """
    GET /pyapi/buildings/count?district=Abbottabad
    Returns total building count and basic stats for a district.
    """
    district = request.args.get("district", "").strip()
    if not district:
        return jsonify(error="district parameter required"), 400
    try:
        gdf = _load_district(district)
        height_col = "height" if "height" in gdf.columns else None
        result = {
            "district": district,
            "total_buildings": len(gdf),
        }
        if height_col:
            result.update({
                "height_min":    round(float(gdf[height_col].min()), 2),
                "height_max":    round(float(gdf[height_col].max()), 2),
                "height_mean":   round(float(gdf[height_col].mean()), 2),
                "height_median": round(float(gdf[height_col].median()), 2),
            })
        return jsonify(result)
    except FileNotFoundError as e:
        return jsonify(error=str(e)), 404
    except Exception as e:
        return jsonify(error=str(e)), 500


# ── Intersection with a GeoJSON polygon ──────────────────────────────────────
@app.route("/pyapi/buildings/intersect", methods=["POST"])
def intersect_buildings():
    """
    POST /pyapi/buildings/intersect
    Body: {
      "district": "Abbottabad",
      "geojson": { GeoJSON FeatureCollection or Feature (polygon/multipolygon) }
    }
    Returns buildings that intersect the given polygon, plus count.

    Use cases:
      - Count buildings inside a flood zone polygon
      - Count buildings inside a hand-drawn bounding polygon
      - Intersect with any uploaded GeoJSON boundary
    """
    body = request.get_json(force=True)
    district = (body.get("district") or "").strip()
    geojson  = body.get("geojson")

    if not district or not geojson:
        return jsonify(error="district and geojson are required"), 400

    try:
        buildings_gdf = _load_district(district)

        # Accept Feature or FeatureCollection
        if geojson.get("type") == "Feature":
            mask_gdf = gpd.GeoDataFrame.from_features([geojson], crs=4326)
        elif geojson.get("type") == "FeatureCollection":
            mask_gdf = gpd.GeoDataFrame.from_features(geojson["features"], crs=4326)
        else:
            # Raw geometry
            mask_gdf = gpd.GeoDataFrame(geometry=[shape(geojson)], crs=4326)

        if mask_gdf.crs.to_epsg() != 4326:
            mask_gdf = mask_gdf.to_crs(epsg=4326)

        # Spatial intersection
        intersected = gpd.overlay(buildings_gdf, mask_gdf, how="intersection")

        return jsonify({
            "district":             district,
            "total_buildings":      len(buildings_gdf),
            "intersecting_count":   len(intersected),
            "intersecting_geojson": json.loads(intersected.to_json()),
        })

    except FileNotFoundError as e:
        return jsonify(error=str(e)), 404
    except Exception as e:
        return jsonify(error=str(e)), 500


# ── Flood susceptibility analysis (existing logic, simplified) ────────────────
@app.route("/pyapi/buildings/flood-analysis")
def flood_analysis():
    """
    GET /pyapi/buildings/flood-analysis?district=Abbottabad
    Counts buildings in each flood susceptibility class (1=low, 2=medium, 3=high).
    This replaces the old GeoServer-download + analyze flow.
    """
    district = request.args.get("district", "").strip()
    if not district:
        return jsonify(error="district parameter required"), 400

    try:
        buildings_gdf = _load_district(district)
        sus_gdf       = gpd.read_file(SUS_GEOJSON).to_crs(epsg=4326)

        joined = gpd.sjoin(buildings_gdf, sus_gdf[["geometry", "class"]],
                           how="left", predicate="intersects")

        counts = (
            joined["class"]
            .fillna(0)
            .astype(int)
            .value_counts()
            .sort_index()
            .to_dict()
        )

        return jsonify({
            "district":        district,
            "total_buildings": len(buildings_gdf),
            "by_class": {
                "no_zone":  counts.get(0, 0),
                "low":      counts.get(1, 0),
                "medium":   counts.get(2, 0),
                "high":     counts.get(3, 0),
            },
        })

    except FileNotFoundError as e:
        return jsonify(error=str(e)), 404
    except Exception as e:
        return jsonify(error=str(e)), 500


# ── Encroachment (buildings inside river polygon) ─────────────────────────────
@app.route("/pyapi/buildings/encroachment/<path:endpoint>")
@app.route("/pyapi/buildings/encroachment")
def encroachment(endpoint=None):
    """
    GET /pyapi/buildings/encroachment?district=Abbottabad
    Returns the river polygon and buildings that fall inside it.
    Preserves the existing API that MapContainer.jsx expects.
    """
    district = request.args.get("district", "").strip()
    if not district:
        return jsonify(error="district parameter required"), 400

    try:
        buildings_gdf    = _load_district(district)
        encroachment_gdf = gpd.read_file(ENCROACHMENT_GEOJSON).to_crs(epsg=4326)

        # Clip to district bbox for speed
        bbox = buildings_gdf.total_bounds  # [minx, miny, maxx, maxy]
        enc_clip = encroachment_gdf.cx[bbox[0]:bbox[2], bbox[1]:bbox[3]]

        if endpoint == "river":
            return Response(enc_clip.to_json(), mimetype="application/json")

        # Buildings inside encroachment polygon
        enc_buildings = gpd.overlay(buildings_gdf, enc_clip, how="intersection")
        return Response(enc_buildings.to_json(), mimetype="application/json")

    except FileNotFoundError as e:
        return jsonify(error=str(e)), 404
    except Exception as e:
        return jsonify(error=str(e)), 500


if __name__ == "__main__":
    port = int(os.environ.get("PYBACKEND_PORT", 7543))
    app.run(host="0.0.0.0", port=port, debug=False)
```

Add `BUILDINGS_DIR` to `.env`:
```bash
BUILDINGS_DIR=C:\HPC\buildings
```

---

## Part 3 — Analysis API Reference

All analysis runs in the Python backend (`pybackend/app.py`) at `http://localhost:7543`.
The client PC makes HTTP requests to this API — no data is stored on the client.

### Building count

```
GET http://localhost:7543/pyapi/buildings/count?district=Abbottabad
```

Response:
```json
{
  "district": "Abbottabad",
  "total_buildings": 84213,
  "height_min": 3.0,
  "height_max": 42.5,
  "height_mean": 7.2,
  "height_median": 6.0
}
```

Call from JavaScript:
```js
const res  = await fetch(`/pyapi/buildings/count?district=${districtName}`);
const data = await res.json();
console.log(`${data.district}: ${data.total_buildings} buildings`);
```

### Intersection — buildings inside any GeoJSON polygon

```
POST http://localhost:7543/pyapi/buildings/intersect
Content-Type: application/json

{
  "district": "Abbottabad",
  "geojson": { <any GeoJSON Feature or FeatureCollection with polygon geometry> }
}
```

Response:
```json
{
  "district": "Abbottabad",
  "total_buildings": 84213,
  "intersecting_count": 1247,
  "intersecting_geojson": { <GeoJSON FeatureCollection of matching buildings> }
}
```

Use cases:
- Pass a flood zone polygon → get count of buildings at risk
- Pass a hand-drawn polygon from a Mapbox draw tool → get buildings inside
- Pass an administrative boundary → get buildings within that sub-area

Call from JavaScript:
```js
// Example: user draws a polygon on map, you get its GeoJSON from Mapbox Draw
const drawnPolygon = draw.getAll();   // GeoJSON FeatureCollection

const res = await fetch('/pyapi/buildings/intersect', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    district: selectedDistrict,
    geojson: drawnPolygon,
  }),
});
const data = await res.json();
console.log(`Buildings in drawn area: ${data.intersecting_count}`);
```

### Flood susceptibility breakdown

```
GET http://localhost:7543/pyapi/buildings/flood-analysis?district=Abbottabad
```

Response:
```json
{
  "district": "Abbottabad",
  "total_buildings": 84213,
  "by_class": {
    "no_zone": 71000,
    "low":      8000,
    "medium":   3500,
    "high":     1713
  }
}
```

### Encroachment (buildings inside river polygons)

```
GET http://localhost:7543/pyapi/buildings/encroachment?district=Abbottabad
GET http://localhost:7543/pyapi/buildings/encroachment/river?district=Abbottabad
```

These endpoints return GeoJSON directly — same API contract as before, so
`MapContainer.jsx` encroachment logic needs no changes.

---

## Part 4 — Running infra_portal After the Migration

### On the HPC (Windows CMD — keep running)

```cmd
:: Terminal 1 — tile server
tileserver-gl-light C:\HPC\tiles\buildings.mbtiles --port 3000

:: Terminal 2 — Python analysis backend (if running on HPC)
cd C:\path\to\infra_portal\pybackend
pip install -r requirements.txt
python app.py
```

### On the client PC

```bash
# Install dependencies (first time)
cd infra_portal
cp .env.example .env
# Edit .env: set MAPBOX_TOKEN, TILE_SERVER_URL=http://172.18.1.174:3000, BUILDINGS_DIR

# Start everything
npm run start        # or ./start.sh
```

The Vite dev server proxies `/pyapi/` to `http://localhost:7543` (Python backend)
and the tile source hits `http://172.18.1.174:3000` directly.

---

## Part 5 — What Does NOT Need to Change

- All flood layer logic in `FloodLayersPanel.jsx` — unchanged
- All province/district boundary GeoJSON loading — unchanged
- `NationalStatsPanel`, `ProvincialStatsPanel`, `DistrictStatsModal` — unchanged
- The `RiskCalculatorModal` — the `flood-analysis` endpoint replaces the old
  download+analyze flow but the response shape is the same
- `EncroachmentModal` — the `/pyapi/buildings/encroachment` endpoints preserve
  the existing API contract
- The Node.js server (`server/index.js`) — unchanged
- GeoServer — can stay running for WMS if needed for other layers; the buildings
  WFS is simply no longer used

---

## Troubleshooting

**`tileserver-gl-light: command not found` (Windows CMD)**
```cmd
npm install -g tileserver-gl-light
:: If npm is not found: install Node.js from nodejs.org first
```

**Height column not working — all buildings appear flat**
```bash
# Check exact column name in WSL:
ogrinfo -al -so "/mnt/c/HPC/buildings/Abbottabad_buildings.shp" | grep -i "height\|floor\|ht\|elev"
# Update HEIGHT_COLUMN in convert.sh and re-run
```

**`convert.sh` reports many "Fallback height" features**
The `HEIGHT_COLUMN` name in the script doesn't match the actual column. See above.

**District buildings not appearing after selecting a district**
The `district` property in the tiles must match `districtKey` in the app.
The script sets `district` = filename stem before `_buildings` (e.g. `Abbottabad`).
The app's `districtKey` comes from the CSV: `Abbottabad_buildings.shp` → `Abbottabad`.
These must be identical. Check both by adding a `console.log(districtKey)` in MapContainer.

**Client can't reach `172.18.1.174:3000`**
```cmd
:: On HPC, run as Administrator:
netsh advfirewall firewall add rule name="TileServer3000" dir=in action=allow protocol=TCP localport=3000
:: Verify HPC IP hasn't changed:
ipconfig
```

**`pyapi/buildings/count` returns 404 — shapefile not found**
Check that `BUILDINGS_DIR` in `.env` points to the folder with `*_buildings.shp` files.
The Python backend matches filenames case-insensitively so `abbottabad` = `Abbottabad`.

**tippecanoe not found in WSL after brew install**
```bash
which tippecanoe   # if not found, brew may not be in PATH
echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> ~/.bashrc
source ~/.bashrc
which tippecanoe
```

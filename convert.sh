#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# convert.sh — Convert each district building shapefile to its own MBTiles file
#
# Input:  BUILDINGS_DIR/*_buildings.shp  (one per district)
# Output: OUTPUT_DIR/*_buildings.mbtiles (one per district, same naming)
#
# Run in WSL Ubuntu on the HPC.
# Prerequisites: gdal-bin, tippecanoe, python3
# ═══════════════════════════════════════════════════════════════════════════════

set -e

# ─── CONFIGURE THESE BEFORE RUNNING ──────────────────────────────────────────
BUILDINGS_DIR="/mnt/c/HPC/buildings"     # folder containing *_buildings.shp
OUTPUT_DIR="/mnt/c/HPC/tiles"            # where *_buildings.mbtiles are saved

HEIGHT_COLUMN="height"                   # exact column name — check with:
                                         # ogrinfo -al -so Abbottabad_buildings.shp

MIN_ZOOM=4
MAX_ZOOM=16
LAYER_NAME="buildings"                   # must match source-layer in MapContainer.jsx
# ─────────────────────────────────────────────────────────────────────────────

mkdir -p "$OUTPUT_DIR"

echo ""
echo "════════════════════════════════════════════════════════"
echo " Processing district shapefiles in: $BUILDINGS_DIR"
echo " Output MBTiles to:                 $OUTPUT_DIR"
echo "════════════════════════════════════════════════════════"

total=0
failed=0

for shp in "$BUILDINGS_DIR"/*_buildings.shp; do
    [ -f "$shp" ] || { echo "ERROR: No *_buildings.shp files found in $BUILDINGS_DIR"; exit 1; }

    name=$(basename "$shp" .shp)                        # e.g. Abbottabad_buildings
    tmp_geojson="$OUTPUT_DIR/${name}.geojson"
    out_mbtiles="$OUTPUT_DIR/${name}.mbtiles"

    echo ""
    echo "──────────────────────────────────────────────────────"
    echo " District: $name"
    echo "──────────────────────────────────────────────────────"

    # Step 1 — convert shapefile to WGS84 GeoJSON
    echo "  [1/3] Converting to GeoJSON..."
    ogr2ogr \
        --config SHAPE_RESTORE_SHX YES \
        -f GeoJSON \
        -t_srs EPSG:4326 \
        "$tmp_geojson" \
        "$shp"

    # Step 2 — add height and base_height fields
    echo "  [2/3] Adding height field..."
    python3 << PYEOF
import json

path       = "$tmp_geojson"
height_col = "$HEIGHT_COLUMN"

with open(path) as f:
    data = json.load(f)

kept = 0
skipped = 0
fallback = 0

out_features = []
for feat in data.get("features", []):
    if feat.get("geometry") is None:
        skipped += 1
        continue
    props = feat.get("properties") or {}
    raw = props.get(height_col)
    try:
        h = float(raw)
        if h <= 0:
            h = 5.0
            fallback += 1
    except (TypeError, ValueError):
        h = 5.0
        fallback += 1
    props["height"]      = round(h, 2)
    props["base_height"] = 0
    feat["properties"]   = props
    out_features.append(feat)
    kept += 1

data["features"] = out_features
with open(path, "w") as f:
    json.dump(data, f)

print(f"     kept={kept}  null_geom_skipped={skipped}  fallback_height={fallback}")
PYEOF

    # Step 3 — tile with tippecanoe
    echo "  [3/3] Tiling..."
    tippecanoe \
        -o "$out_mbtiles" \
        --force \
        -Z "$MIN_ZOOM" \
        -z "$MAX_ZOOM" \
        --drop-densest-as-needed \
        --extend-zooms-if-still-dropping \
        --detect-shared-borders \
        --simplification=2 \
        --read-parallel \
        -P \
        -l "$LAYER_NAME" \
        "$tmp_geojson" 2>&1 | tail -2

    # Remove intermediate GeoJSON
    rm "$tmp_geojson"

    size=$(ls -lh "$out_mbtiles" | awk '{print $5}')
    echo "  Done → $(basename $out_mbtiles)  ($size)"
    total=$((total + 1))
done

echo ""
echo "════════════════════════════════════════════════════════"
echo " ALL DONE — $total district(s) converted"
echo ""
ls -lh "$OUTPUT_DIR"/*.mbtiles
echo ""
WIN_DIR=$(echo "$OUTPUT_DIR" | sed 's|/mnt/c|C:|' | sed 's|/|\\|g')
echo " Windows path: $WIN_DIR"
echo ""
echo " Serve all districts with one command (Windows CMD):"
echo "   tileserver-gl-light --mbtiles $WIN_DIR --port 3000"
echo ""
echo " Tile URLs:"
echo "   http://172.18.1.174:3000/data/Abbottabad_buildings/{z}/{x}/{y}.pbf"
echo "   http://172.18.1.174:3000/data/Mardan_buildings/{z}/{x}/{y}.pbf"
echo "   http://172.18.1.174:3000/data/<District>_buildings/{z}/{x}/{y}.pbf"
echo "════════════════════════════════════════════════════════"

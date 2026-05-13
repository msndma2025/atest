#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# convert.sh — Convert all district building shapefiles to a single MBTiles file
#
# Run this in WSL Ubuntu on the HPC. Once the .mbtiles file is produced,
# everything else (serving, visualization, analysis) runs on Windows natively.
#
# Usage:
#   bash convert.sh
#
# Prerequisites (install once in WSL — see README.md for full commands):
#   sudo apt install gdal-bin build-essential libsqlite3-dev zlib1g-dev python3
#   brew install tippecanoe   OR   build tippecanoe from source
# ═══════════════════════════════════════════════════════════════════════════════

set -e

# ─── CONFIGURE THESE BEFORE RUNNING ──────────────────────────────────────────

# Folder containing all *_buildings.shp files
# Windows path C:\HPC\buildings → WSL path /mnt/c/HPC/buildings
BUILDINGS_DIR="/mnt/c/HPC/buildings"

# Folder where output files will be saved
OUTPUT_DIR="/mnt/c/HPC/tiles"

# Exact column name in your shapefiles that holds building height (metres)
# Check with: ogrinfo -al -so /mnt/c/HPC/buildings/Abbottabad_buildings.shp
HEIGHT_COLUMN="height"

# Zoom levels
MIN_ZOOM=4      # lowest zoom — country/region overview
MAX_ZOOM=16     # highest zoom — individual building detail (use 18 for very dense cities)

# Vector layer name — must exactly match 'source-layer' in MapContainer.jsx
LAYER_NAME="buildings"

# ─────────────────────────────────────────────────────────────────────────────

MERGED_GEOJSON="$OUTPUT_DIR/merged_buildings.geojson"
OUTPUT_MBTILES="$OUTPUT_DIR/buildings.mbtiles"

mkdir -p "$OUTPUT_DIR"

echo ""
echo "══════════════════════════════════════════════════════════"
echo " STEP 1 — Converting each *_buildings.shp to GeoJSON"
echo "══════════════════════════════════════════════════════════"

file_count=0

for shp in "$BUILDINGS_DIR"/*_buildings.shp; do
    [ -f "$shp" ] || { echo "ERROR: No *_buildings.shp files found in $BUILDINGS_DIR"; exit 1; }

    name=$(basename "$shp" .shp)                   # e.g. Abbottabad_buildings
    out_geojson="$OUTPUT_DIR/${name}.geojson"

    echo "  → $name"

    ogr2ogr \
        --config SHAPE_RESTORE_SHX YES \
        -f GeoJSON \
        -t_srs EPSG:4326 \
        "$out_geojson" \
        "$shp"

    file_count=$((file_count + 1))
done

echo "  Done — converted $file_count shapefile(s)"

echo ""
echo "══════════════════════════════════════════════════════════"
echo " STEP 2 — Adding height + district fields, merging all"
echo "══════════════════════════════════════════════════════════"

python3 << PYEOF
import json, os, glob

output_dir     = "$OUTPUT_DIR"
height_col     = "$HEIGHT_COLUMN"
merged_path    = "$MERGED_GEOJSON"

all_features   = []
null_geom      = 0
fallback_count = 0

for path in sorted(glob.glob(os.path.join(output_dir, "*_buildings.geojson"))):
    if "merged" in os.path.basename(path):
        continue

    # Extract district name from filename: "Abbottabad_buildings.geojson" → "Abbottabad"
    district = os.path.basename(path).replace("_buildings.geojson", "")
    print(f"  Merging: {district}")

    with open(path) as f:
        data = json.load(f)

    for feat in data.get("features", []):
        if feat.get("geometry") is None:
            null_geom += 1
            continue

        props = feat.get("properties") or {}

        # ── Height ────────────────────────────────────────────────────────────
        raw = props.get(height_col)
        try:
            h = float(raw)
            if h <= 0:
                h = 5.0
                fallback_count += 1
        except (TypeError, ValueError):
            h = 5.0
            fallback_count += 1
        # ─────────────────────────────────────────────────────────────────────

        props["height"]      = round(h, 2)
        props["base_height"] = 0
        props["district"]    = district   # used for filtering in Mapbox GL JS
        feat["properties"]   = props
        all_features.append(feat)

print(f"\n  Total features  : {len(all_features):,}")
print(f"  Null geometries : {null_geom:,}  (skipped)")
print(f"  Fallback height : {fallback_count:,}  (set to 5 m — check HEIGHT_COLUMN name)")

merged = {"type": "FeatureCollection", "features": all_features}
with open(merged_path, "w") as f:
    json.dump(merged, f)

print(f"\n  Written → {merged_path}")
PYEOF

echo ""
echo "══════════════════════════════════════════════════════════"
echo " STEP 3 — Tiling with tippecanoe"
echo "══════════════════════════════════════════════════════════"
echo "  Input  : $MERGED_GEOJSON"
echo "  Output : $OUTPUT_MBTILES"
echo "  Zooms  : $MIN_ZOOM → $MAX_ZOOM"
echo "  Layer  : $LAYER_NAME"
echo ""

tippecanoe \
    -o "$OUTPUT_MBTILES" \
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
    "$MERGED_GEOJSON"

echo ""
echo "══════════════════════════════════════════════════════════"
echo " STEP 4 — Cleaning up intermediate GeoJSON files"
echo "══════════════════════════════════════════════════════════"

for f in "$OUTPUT_DIR"/*_buildings.geojson "$MERGED_GEOJSON"; do
    [ -f "$f" ] && rm "$f" && echo "  Deleted: $(basename $f)"
done

echo ""
echo "══════════════════════════════════════════════════════════"
echo " ALL DONE"
echo "══════════════════════════════════════════════════════════"
echo ""
ls -lh "$OUTPUT_MBTILES"
echo ""

# Convert WSL path back to Windows path for display
WIN_PATH=$(echo "$OUTPUT_MBTILES" | sed 's|/mnt/c|C:|' | sed 's|/|\\|g')
echo " Windows path: $WIN_PATH"
echo ""
echo " Next — open Windows CMD and run:"
echo "   tileserver-gl-light $WIN_PATH --port 3000"
echo ""
echo " Tile URL for infra_portal:"
echo "   http://172.18.1.174:3000/data/buildings/{z}/{x}/{y}.pbf"
echo ""

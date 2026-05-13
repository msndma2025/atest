#!/bin/bash
# convert.sh — Convert each district building shapefile to its own MBTiles file
#
# Input:  BUILDINGS_DIR/*_buildings.shp  (one per district, already has height column)
# Output: OUTPUT_DIR/*_buildings.mbtiles (one per district, same naming)
#
# Run in WSL Ubuntu on the HPC.
# Prerequisites: gdal-bin, tippecanoe

set -e

# ─── CONFIGURE THESE ─────────────────────────────────────────────────────────
BUILDINGS_DIR="/mnt/c/HPC/buildings"
OUTPUT_DIR="/mnt/c/HPC/tiles"
MIN_ZOOM=4
MAX_ZOOM=16
LAYER_NAME="buildings"
# ─────────────────────────────────────────────────────────────────────────────

mkdir -p "$OUTPUT_DIR"

echo "Input:  $BUILDINGS_DIR"
echo "Output: $OUTPUT_DIR"
echo ""

total=0

for shp in "$BUILDINGS_DIR"/*_buildings.shp; do
    [ -f "$shp" ] || { echo "ERROR: No *_buildings.shp files found in $BUILDINGS_DIR"; exit 1; }

    name=$(basename "$shp" .shp)                   # e.g. Mardan_buildings
    tmp_geojson="$OUTPUT_DIR/${name}.geojson"
    out_mbtiles="$OUTPUT_DIR/${name}.mbtiles"

    echo "── $name"

    ogr2ogr \
        --config SHAPE_RESTORE_SHX YES \
        -f GeoJSON \
        -t_srs EPSG:4326 \
        "$tmp_geojson" \
        "$shp"

    tippecanoe \
        -o "$out_mbtiles" \
        --force \
        -Z "$MIN_ZOOM" \
        -z "$MAX_ZOOM" \
        --drop-densest-as-needed \
        --extend-zooms-if-still-dropping \
        --read-parallel \
        -P \
        -l "$LAYER_NAME" \
        "$tmp_geojson" 2>&1 | tail -1

    rm "$tmp_geojson"

    echo "   → $(basename $out_mbtiles)  ($(ls -lh "$out_mbtiles" | awk '{print $5}'))"
    total=$((total + 1))
done

echo ""
echo "Done — $total district(s) converted"
ls -lh "$OUTPUT_DIR"/*.mbtiles

# Generate config.json for tileserver-gl (relative paths — works on Windows)
python3 << 'PYEOF'
import json, glob, os
output_dir = os.environ.get("OUTPUT_DIR", ".")
files = sorted(glob.glob(os.path.join(output_dir, "*.mbtiles")))
config = {"data": {os.path.basename(f).replace(".mbtiles",""): {"mbtiles": os.path.basename(f)} for f in files}}
out = os.path.join(output_dir, "config.json")
with open(out, "w") as f:
    json.dump(config, f, indent=2)
print(f"config.json written — {len(config['data'])} dataset(s)")
PYEOF

WIN_DIR=$(echo "$OUTPUT_DIR" | sed 's|/mnt/c|C:|' | sed 's|/|\\|g')
echo ""
echo "Serve on Windows CMD:"
echo "  cd $WIN_DIR"
echo "  tileserver-gl --config config.json --port 8081"

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

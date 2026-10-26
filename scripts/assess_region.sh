#!/usr/bin/env bash
# Summarise statutory designations across the study region and build the
# terrain backdrop for the overview map.
#
# Usage: scripts/assess_region.sh
#
# Writes output/region/:
#   region.gpkg     region, areas, catchments, rivers and designations, for maps
#                   and QGIS
#   region.duckdb   every intermediate table, for ad hoc SQL
#   hillshade.tif   REGION_RELIEF_M multidirectional hillshade of STUDY_BBOX
set -euo pipefail

cd "$(dirname "$0")/.."
source config.env

OUT=output/region
LAYERS=$OUT/layers

for input in data/designations.gpkg data/catchments.gpkg; do
  if [[ ! -f $input ]]; then
    echo "Missing $input; run scripts/fetch_designations.sh and scripts/fetch_region.sh" >&2
    exit 1
  fi
done

rm -rf "$LAYERS" "$OUT/region.duckdb" "$OUT/region.gpkg"
mkdir -p "$LAYERS"

duckdb -storage-version latest "$OUT/region.duckdb" \
  -cmd "SET VARIABLE designations = 'data/designations.gpkg';" \
  -cmd "SET VARIABLE catchments = 'data/catchments.gpkg';" \
  -cmd "SET VARIABLE catchment_table = 'region/catchments.csv';" \
  -cmd "SET VARIABLE layers_dir = '$LAYERS';" \
  -f sql/assess_region.sql

for layer in region areas catchments rivers open_access consult scheduled_monuments listed_buildings; do
  update=""
  [[ -f $OUT/region.gpkg ]] && update=-update
  ogr2ogr -f GPKG $update "$OUT/region.gpkg" "$LAYERS/$layer.fgb" -nln "$layer"
done

# Terrain backdrop. The DTM is fetched at half the target resolution and
# averaged down, which removes the grid pattern in the service's own overviews.
IFS=, read -r xmin ymin xmax ymax <<< "$STUDY_BBOX"
scripts/fetch_dtm.sh "$xmin" "$ymin" "$xmax" "$ymax" $((REGION_RELIEF_M / 2)) "$OUT/dtm_fine.tif"
gdalwarp -q -overwrite -r average -tr "$REGION_RELIEF_M" "$REGION_RELIEF_M" \
  -te "$xmin" "$ymin" "$xmax" "$ymax" -co COMPRESS=DEFLATE -co PREDICTOR=3 \
  "$OUT/dtm_fine.tif" "$OUT/dtm.tif"
rm "$OUT/dtm_fine.tif"
gdaldem hillshade -q -multidirectional -compute_edges -co COMPRESS=DEFLATE \
  "$OUT/dtm.tif" "$OUT/hillshade.tif"

echo "Wrote $OUT"

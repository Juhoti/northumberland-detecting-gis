#!/usr/bin/env bash
# Build LiDAR terrain visualisations for one area of interest.
#
# Usage: scripts/build_terrain.sh [boundary file]
#   Run scripts/assess_aoi.sh on the same boundary first.
#
# The 1 m DTM is fetched from the Environment Agency for the AOI extent plus
# TERRAIN_BUFFER_M only, never the wider landscape. Products are written to
# output/<name>/terrain/:
#   dtm.tif        1 m digital terrain model
#   hillshade.tif  multidirectional hillshade
#   slope.tif      slope in degrees
#   lrm.tif        local relief model: DTM minus its LRM_WINDOW_M focal mean
#   *_stats.csv    elevation and slope statistics inside the AOI
set -euo pipefail

cd "$(dirname "$0")/.."
source config.env

AOI_FILE=${1:-$AOI}
NAME=$(basename "${AOI_FILE%.*}")
OUT=output/$NAME
TERRAIN=$OUT/terrain
BOUNDARY=$OUT/layers/aoi.fgb

if [[ ! -f $BOUNDARY ]]; then
  echo "Missing $BOUNDARY; run scripts/assess_aoi.sh first" >&2
  exit 1
fi

rm -rf "$TERRAIN"
mkdir -p "$TERRAIN"

# AOI extent rounded outward to whole metres, plus the display buffer.
read -r xmin ymin xmax ymax < <(
  ogrinfo -ro -so -al "$BOUNDARY" |
    sed -n 's/^Extent: (\([0-9.]*\), \([0-9.]*\)) - (\([0-9.]*\), \([0-9.]*\))/\1 \2 \3 \4/p' |
    awk -v b="$TERRAIN_BUFFER_M" '{
      printf "%d %d %d %d\n", int($1) - b, int($2) - b, int($3 + 0.999) + b, int($4 + 0.999) + b
    }'
)

# Process a wider window so filters and hillshading have no edge effects
# inside the final extent.
pad=$((LRM_WINDOW_M + 10))
window=$((LRM_WINDOW_M / 2 * 2 + 1))   # odd kernel size in 1 m pixels

FLOAT=(-co COMPRESS=DEFLATE -co PREDICTOR=3 -co TILED=YES)
BYTE=(-co COMPRESS=DEFLATE -co PREDICTOR=2 -co TILED=YES)

scripts/fetch_dtm.sh $((xmin - pad)) $((ymin - pad)) $((xmax + pad)) $((ymax + pad)) 1 \
  "$TERRAIN/dtm_pad.tif"

gdaldem hillshade -q -multidirectional -compute_edges "${BYTE[@]}" \
  "$TERRAIN/dtm_pad.tif" "$TERRAIN/hillshade_pad.tif"

gdaldem slope -q -compute_edges "${FLOAT[@]}" \
  "$TERRAIN/dtm_pad.tif" "$TERRAIN/slope_pad.tif"

# Local relief model: subtract the large-scale landform (focal mean) so that
# banks, ditches and ridge-and-furrow stand out regardless of hillside shading.
gdal raster neighbors -q --kernel equal --size "$window" --method mean --ot Float32 \
  "$TERRAIN/dtm_pad.tif" "$TERRAIN/smooth_pad.tif"

PYTHONWARNINGS=ignore::FutureWarning gdal_calc --quiet \
  -A "$TERRAIN/dtm_pad.tif" -B "$TERRAIN/smooth_pad.tif" \
  --calc "A - B" --type Float32 --NoDataValue=-9999 \
  --outfile "$TERRAIN/lrm_pad.tif"

for product in dtm hillshade slope lrm; do
  opts=("${FLOAT[@]}")
  [[ $product == hillshade ]] && opts=("${BYTE[@]}")
  gdal_translate -q "${opts[@]}" -projwin "$xmin" "$ymax" "$xmax" "$ymin" \
    "$TERRAIN/${product}_pad.tif" "$TERRAIN/$product.tif"
done
rm "$TERRAIN"/*_pad.tif

# Terrain statistics inside the AOI boundary.
for product in dtm slope; do
  gdal raster zonal-stats -q -i "$TERRAIN/$product.tif" --zones "$BOUNDARY" \
    --stat min --stat max --stat mean -f CSV -o "$TERRAIN/${product}_stats.csv" --overwrite
done

echo "Wrote $TERRAIN (extent $xmin $ymin $xmax $ymax)"

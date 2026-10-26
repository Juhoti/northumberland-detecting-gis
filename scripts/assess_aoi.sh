#!/usr/bin/env bash
# Assess one area of interest against the downloaded designations.
#
# Usage: scripts/assess_aoi.sh [boundary file]
#   The boundary defaults to AOI in config.env. Any vector format GDAL reads
#   (GeoJSON, GeoPackage, KML, shapefile) in any CRS is accepted.
#
# Writes output/<name>/<name>.gpkg (all layers) and output/<name>/assessment.duckdb.
set -euo pipefail

cd "$(dirname "$0")/.."
source config.env

AOI_FILE=${1:-$AOI}
NAME=$(basename "${AOI_FILE%.*}")
OUT=output/$NAME
LAYERS=$OUT/layers
DESIGNATIONS=data/designations.gpkg

if [[ ! -f $DESIGNATIONS ]]; then
  echo "Missing $DESIGNATIONS; run scripts/fetch_designations.sh first" >&2
  exit 1
fi

rm -rf "$LAYERS" "$OUT/assessment.duckdb" "$OUT/$NAME.gpkg"
mkdir -p "$LAYERS"

# Normalise the boundary to 2D British National Grid before any analysis.
ogr2ogr -f FlatGeobuf -t_srs EPSG:27700 -dim XY -nln aoi_input \
  "$LAYERS/aoi_input.fgb" "$AOI_FILE"

# Designations were downloaded for STUDY_BBOX only. A boundary outside it would
# come back wrongly unconstrained, so refuse it.
inside=$(
  ogrinfo -ro -so -al "$LAYERS/aoi_input.fgb" |
    sed -n 's/^Extent: (\(.*\), \(.*\)) - (\(.*\), \(.*\))/\1 \2 \3 \4/p' |
    awk -v bbox="$STUDY_BBOX" -v r="$CONTEXT_RADIUS_M" '{
      split(bbox, b, ",")
      print ($1 - r >= b[1] && $2 - r >= b[2] && $3 + r <= b[3] && $4 + r <= b[4]) ? "yes" : "no"
    }'
)
if [[ $inside != yes ]]; then
  echo "$AOI_FILE extends outside STUDY_BBOX ($STUDY_BBOX) once the ${CONTEXT_RADIUS_M} m" >&2
  echo "context radius is added. Widen STUDY_BBOX in config.env and run 'make refresh'." >&2
  exit 1
fi

duckdb -storage-version latest "$OUT/assessment.duckdb" \
  -cmd "SET VARIABLE aoi_path = '$LAYERS/aoi_input.fgb';" \
  -cmd "SET VARIABLE designations = '$DESIGNATIONS';" \
  -cmd "SET VARIABLE layers_dir = '$LAYERS';" \
  -cmd "SET VARIABLE gps_margin_m = $GPS_MARGIN_M;" \
  -cmd "SET VARIABLE context_radius_m = $CONTEXT_RADIUS_M;" \
  -f sql/assess_aoi.sql

# Collect the layers into one GeoPackage for QGIS.
for layer in aoi available no_go consult scheduled_nearby listed_nearby; do
  update=""
  [[ -f $OUT/$NAME.gpkg ]] && update=-update
  ogr2ogr -f GPKG $update "$OUT/$NAME.gpkg" "$LAYERS/$layer.fgb" -nln "$layer"
done

echo "Wrote $OUT/$NAME.gpkg"

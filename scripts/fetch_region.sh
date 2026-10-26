#!/usr/bin/env bash
# Download the river catchments that define the study region from the
# Environment Agency Catchment Data Explorer, in British National Grid.
#
# Usage: scripts/fetch_region.sh [output.gpkg]
#
# region/catchments.csv lists the Water Framework Directive operational
# catchments in the region. Each one is published as GeoJSON holding its
# waterbody catchments (polygons) and river lines. The output has two layers,
# both tagged with catchment_id:
#   waterbodies  waterbody catchment polygons
#   rivers       river lines
set -euo pipefail

cd "$(dirname "$0")/.."

OUT=${1:-data/catchments.gpkg}
SOURCE=https://environment.data.gov.uk/catchment-planning/OperationalCatchment
RAW=$(mktemp -d)
trap 'rm -rf "$RAW"' EXIT

TMP=$RAW/catchments.gpkg
mkdir -p "$(dirname "$OUT")"

# append <GeoJSON> <catchment id> <layer> <geometry-type suffix> <geometry type>
append() {
  local update=""
  [[ -f $TMP ]] && update="-update -append"
  ogr2ogr -f GPKG $update "$TMP" "$1" -nln "$3" -nlt "$5" \
    -s_srs EPSG:4326 -t_srs EPSG:27700 -dialect SQLite \
    -sql "SELECT geometry AS geom, id AS waterbody_id, name, $2 AS catchment_id
          FROM \"$(basename "$1" .geojson)\" WHERE \"geometry-type\" LIKE '%/$4'"
}

# Download everything first, so a failed request leaves any earlier output intact.
tail -n +2 region/catchments.csv | while IFS=, read -r id catchment area; do
  curl -sSf --retry 5 --retry-all-errors -m 120 -o "$RAW/$id.geojson" "$SOURCE/$id.geojson"
done

tail -n +2 region/catchments.csv | while IFS=, read -r id catchment area; do
  append "$RAW/$id.geojson" "$id" waterbodies Catchment MULTIPOLYGON
  append "$RAW/$id.geojson" "$id" rivers RiverLine MULTILINESTRING
  printf '%-18s %-22s %s\n' "$catchment" "($area)" "$id"
done

mv "$TMP" "$OUT"
echo "Wrote $OUT"

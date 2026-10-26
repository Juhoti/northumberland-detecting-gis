#!/usr/bin/env bash
# Download statutory designations for the study extent from the Historic England
# and Natural England ArcGIS feature services, in British National Grid.
#
# Usage: scripts/fetch_designations.sh [output.gpkg]
set -euo pipefail

cd "$(dirname "$0")/.."
source config.env

OUT=${1:-data/designations.gpkg}
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

NHLE=https://services-eu1.arcgis.com/ZOdPfBS3aqqDYPUQ/arcgis/rest/services/National_Heritage_List_for_England_NHLE_v02_VIEW/FeatureServer
NE=https://services.arcgis.com/JJzESW51TqeY9uat/arcgis/rest/services

# fetch <feature layer URL> <output layer name> <geometry type>
# The explicit geometry type keeps empty layers usable downstream.
fetch() {
  local url=$1 layer=$2 geomtype=$3
  local query="where=1%3D1&geometry=${STUDY_BBOX}&geometryType=esriGeometryEnvelope&inSR=27700&spatialRel=esriSpatialRelIntersects&outFields=*&outSR=27700&f=json"
  local update=""
  [[ -f $OUT ]] && update=-update
  ogr2ogr -f GPKG $update "$OUT" "ESRIJSON:${url}/query?${query}" \
    -nln "$layer" -nlt "$geomtype" -a_srs EPSG:27700

  # An empty response carries no field definitions. Rebuild the layer from one
  # sample feature, filtered out locally, so downstream SQL sees the full schema.
  if [[ $(count "$layer") == 0 ]]; then
    ogr2ogr -f GPKG -update -overwrite "$OUT" \
      "ESRIJSON:${url}/query?where=1%3D1&resultRecordCount=1&outFields=*&outSR=27700&f=json" \
      -where "1=0" -nln "$layer" -nlt "$geomtype" -a_srs EPSG:27700 \
      --config OGR_ORGANIZE_POLYGONS SKIP
  fi
  printf '%-22s %5s features\n' "$layer" "$(count "$layer")"
}

count() {
  ogrinfo -ro -so "$OUT" "$1" | awk -F': ' '/Feature Count/ {print $2}'
}

# Historic England: National Heritage List for England
fetch "$NHLE/6"  scheduled_monuments  MULTIPOLYGON
fetch "$NHLE/7"  parks_and_gardens    MULTIPOLYGON
fetch "$NHLE/8"  battlefields         MULTIPOLYGON
fetch "$NHLE/10" world_heritage_sites MULTIPOLYGON
fetch "$NHLE/0"  listed_buildings     MULTIPOINT

# Natural England
fetch "$NE/SSSI_England/FeatureServer/0" sssi MULTIPOLYGON
fetch "$NE/CRoW_Act_2000_Section_4_Conclusive_Open_Country/FeatureServer/0" crow_open_country MULTIPOLYGON

echo "Wrote $OUT"

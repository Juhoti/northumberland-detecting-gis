#!/usr/bin/env bash
# Fetch the Environment Agency LiDAR Composite DTM for a window in British
# National Grid.
#
# Usage: scripts/fetch_dtm.sh <xmin> <ymin> <xmax> <ymax> <resolution m> <output.tif>
#
# Reads the EA Web Coverage Service (WCS 2.0.1) in chunks aligned to a fixed
# grid and caches each chunk in data/dtm/<resolution>m/, so repeat runs and
# neighbouring areas reuse earlier downloads. At 1 m the values are identical
# to the 5 km tiles on the Defra survey portal. Coarser resolutions are
# resampled by the server.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -ne 6 ]]; then
  echo "Usage: $0 <xmin> <ymin> <xmax> <ymax> <resolution m> <output.tif>" >&2
  exit 1
fi
xmin=$1 ymin=$2 xmax=$3 ymax=$4 res=$5 out=$6

WCS=https://environment.data.gov.uk/geoservices/datasets/13787b9a-26a4-4775-8523-806d13af58fc/wcs
COVERAGE=13787b9a-26a4-4775-8523-806d13af58fc__Lidar_Composite_Elevation_DTM_1m
CACHE=data/dtm/${res}m

# Chunks of at most 1000 pixels and 10 km a side. Larger requests can come back
# with whole blocks missing.
CHUNK=$((res * 1000))
((CHUNK > 10000)) && CHUNK=10000

SCALE=""
[[ $res != 1 ]] && SCALE="&SCALEFACTOR=$(awk -v r="$res" 'BEGIN { print 1 / r }')"

# fetch_chunk <easting> <northing> <file>: download one chunk, keeping it only
# if GDAL can read the response. Where the service holds no data at all
# (Scotland, open sea) it returns zeros without a NoData value, or HTTP 500 for
# resampled requests. Both are recorded as an empty chunk rather than stored.
fetch_chunk() {
  local e=$1 n=$2 file=$3 status info
  local url="$WCS?service=WCS&version=2.0.1&request=GetCoverage&CoverageId=$COVERAGE"
  url+="&format=image/tiff&subset=E($e,$((e + CHUNK)))&subset=N($n,$((n + CHUNK)))$SCALE"
  status=$(curl -sS --retry 3 -m 300 -o "$file.part" -w "%{http_code}" "$url" || true)
  if [[ $status == 200 ]] && info=$(gdalinfo -mm "$file.part" 2>/dev/null); then
    if [[ $info == *"Min/Max=0.000,0.000"* && $info != *"NoData Value"* ]]; then
      rm -f "$file.part"
      touch "$file.empty"
    else
      mv "$file.part" "$file"
    fi
  elif [[ $status == 500 && -n $SCALE ]]; then
    rm -f "$file.part"
    touch "$file.empty"
  else
    echo "Failed to fetch $file (HTTP $status)" >&2
    rm -f "$file.part"
    return 255   # stops xargs
  fi
}
export -f fetch_chunk
export WCS COVERAGE CHUNK SCALE

mkdir -p "$CACHE"
list=$(mktemp)
trap 'rm -f "$list" "$list.vrt"' EXIT

# Chunk origins covering the window, snapped outward to the chunk grid.
chunks=()
for ((e = xmin / CHUNK * CHUNK; e < xmax; e += CHUNK)); do
  for ((n = ymin / CHUNK * CHUNK; n < ymax; n += CHUNK)); do
    chunks+=("$e $n $CACHE/E${e}_N${n}.tif")
  done
done

for chunk in "${chunks[@]}"; do
  read -r e n file <<< "$chunk"
  [[ -s $file || -f $file.empty ]] || echo "$chunk"
done | xargs -P 4 -n 3 bash -c 'fetch_chunk "$@"' _

for chunk in "${chunks[@]}"; do
  read -r e n file <<< "$chunk"
  if [[ -s $file ]]; then echo "$file"; fi
done > "$list"

if [[ ! -s $list ]]; then
  echo "No LiDAR coverage for $xmin $ymin $xmax $ymax" >&2
  exit 1
fi

gdalbuildvrt -q -overwrite -input_file_list "$list" "$list.vrt"
gdal_translate -q -co COMPRESS=DEFLATE -co PREDICTOR=3 -co TILED=YES \
  -projwin "$xmin" "$ymax" "$xmax" "$ymin" "$list.vrt" "$out"

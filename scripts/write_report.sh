#!/usr/bin/env bash
# Write a Markdown report for one assessed area of interest.
#
# Usage: scripts/write_report.sh [boundary file]
#   Run assess_aoi.sh, build_terrain.sh and render_maps.py first.
set -euo pipefail

cd "$(dirname "$0")/.."
source config.env

AOI_FILE=${1:-$AOI}
NAME=$(basename "${AOI_FILE%.*}")
OUT=output/$NAME
DB=$OUT/assessment.duckdb
REPORT=$OUT/report.md

# Run a query against the assessment database and print a Markdown table.
table() {
  duckdb -readonly -markdown "$DB" -c "$1"
}

# Run a query and print its single value.
value() {
  duckdb -readonly -noheader -list "$DB" -c "$1"
}

none() {
  local rows
  rows=$(value "SELECT count(*) FROM ($1)")
  [[ $rows == 0 ]]
}

section() {
  local query=$1 empty=$2
  if none "$query"; then echo "$empty"; else table "$query"; fi
}

link="'[' || ref || '](' || url || ')'"

{
  echo "# Constraint report: ${NAME//_/ }"
  echo
  echo "Generated $(date +%Y-%m-%d) from \`$AOI_FILE\`. Designations downloaded"
  echo "$(date -r data/designations.gpkg +%Y-%m-%d) from Historic England and Natural England."
  echo
  echo "Parameters: ${GPS_MARGIN_M} m GPS margin around scheduled monuments;"
  echo "records listed within ${CONTEXT_RADIUS_M} m of the boundary."
  echo
  echo "## Summary"
  echo
  table "SELECT measure AS \"Measure\", hectares AS \"Hectares\", percent AS \"% of area\" FROM summary"
  echo
  echo "![Constraints map](constraints.png)"
  echo
  echo "## No-go: scheduled monuments inside the area"
  echo
  echo "Using a metal detector on a scheduled monument without written consent is an"
  echo "offence under section 42 of the Ancient Monuments and Archaeological Areas Act 1979."
  echo
  section "SELECT $link AS \"List entry\", name AS \"Name\",
             sum(area_ha) FILTER (kind = 'scheduled area') AS \"Inside area (ha)\",
             sum(area_ha) FILTER (kind = 'GPS margin') AS \"Margin (ha)\"
           FROM no_go GROUP BY ref, name, url ORDER BY ref" \
    "None."
  echo
  echo "## Scheduled monuments near the area"
  echo
  section "SELECT $link AS \"List entry\", name AS \"Name\", distance_m AS \"Distance (m)\"
           FROM nearby
           WHERE designation = 'Scheduled monument' AND NOT overlaps_aoi
           ORDER BY distance_m" \
    "None within ${CONTEXT_RADIUS_M} m."
  echo
  echo "## Other designations inside the area"
  echo
  section "SELECT designation AS \"Designation\",
             CASE WHEN url IS NULL THEN name ELSE '[' || name || '](' || url || ')' END AS \"Name\",
             class AS \"Class\", sum(area_ha) AS \"Inside area (ha)\", guidance AS \"Guidance\"
           FROM consult GROUP BY ALL ORDER BY class, designation" \
    "None."
  echo
  echo "## Listed buildings within ${CONTEXT_RADIUS_M} m"
  echo
  section "SELECT $link AS \"List entry\", name AS \"Name\", grade AS \"Grade\",
             distance_m AS \"Distance (m)\"
           FROM listed_nearby ORDER BY distance_m, grade, name" \
    "None."
  echo
  echo "## Terrain"
  echo
  table "SELECT 'Elevation (m)' AS \"Measure\", round(min, 1) AS \"Min\", round(max, 1) AS \"Max\",
           round(mean, 1) AS \"Mean\" FROM read_csv('$OUT/terrain/dtm_stats.csv')
         UNION ALL
         SELECT 'Slope (degrees)', round(min, 1), round(max, 1), round(mean, 1)
         FROM read_csv('$OUT/terrain/slope_stats.csv')"
  echo
  echo "![Local relief model](relief.jpg)"
  echo
  echo "## Before detecting"
  echo
  echo "- Written permission from the landowner and, where different, the occupier."
  echo "- Check each list entry above for changes since the download date."
  echo "- Follow the Code of Practice for Responsible Metal Detecting in England and Wales."
  echo "- Report potential Treasure to the coroner within 14 days (Treasure Act 1996) and"
  echo "  record other finds with the Portable Antiquities Scheme."
  echo
  echo "This report summarises public designation data. It is not legal advice."
} > "$REPORT"

echo "Wrote $REPORT"

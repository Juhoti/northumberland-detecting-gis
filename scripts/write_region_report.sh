#!/usr/bin/env bash
# Write a Markdown report for the regional overview.
#
# Usage: scripts/write_region_report.sh
#   Run scripts/assess_region.sh and scripts/render_region.py first.
set -euo pipefail

cd "$(dirname "$0")/.."
source config.env

OUT=output/region
DB=$OUT/region.duckdb
REPORT=$OUT/report.md

table() {
  duckdb -readonly -markdown "$DB" -c "LOAD spatial; $1"
}

link="'[' || name || '](' || url || ')'"
cde="'[' || catchment_id || '](https://environment.data.gov.uk/catchment-planning/OperationalCatchment/' || catchment_id || ')'"

{
  echo "# Regional overview: border country and Coquetdale"
  echo
  echo "Generated $(date +%Y-%m-%d). Designations downloaded"
  echo "$(date -r data/designations.gpkg +%Y-%m-%d) from Historic England and Natural England."
  echo
  echo "The overview summarises where statutory designations lie across the region."
  echo "It does not show where to detect: that depends on the landowner's permission,"
  echo "and each permission is checked separately with the area assessment."
  echo
  echo "![Overview map](overview.png)"
  echo
  echo "## Region"
  echo
  echo "The region is built from Environment Agency Water Framework Directive"
  echo "operational catchments, listed in \`region/catchments.csv\`. The border country"
  echo "is the land draining to the Tweed (through the Till), the Rede and the upper"
  echo "North Tyne; Coquetdale is the Coquet catchment from its source to the tidal limit."
  echo
  table "SELECT area AS \"Area\", catchment AS \"Catchment\", $cde AS \"EA catchment\",
                round(ST_Area(geom) / 1e6, 1) AS \"km²\"
         FROM catchments
         JOIN (SELECT area, ord FROM units) USING (area)
         ORDER BY ord, catchment DESC"
  echo
  echo "## Summary by area"
  echo
  echo "Counts are records that touch each area; a record crossing an area boundary"
  echo "counts in both, but once for the whole region. Percentages are of land area,"
  echo "measured on dissolved geometries so overlapping records count once."
  echo
  table "SELECT area AS \"Area\", area_km2 AS \"km²\",
                scheduled_monuments AS \"Scheduled monuments\",
                scheduled_pct AS \"Scheduled land %\",
                listed_buildings AS \"Listed buildings\",
                sssis AS \"SSSIs\", sssi_pct AS \"SSSI %\",
                access_pct AS \"Open access land %\"
         FROM summary"
  echo
  echo "## Whole region by designation"
  echo
  table "SELECT designation AS \"Designation\", class AS \"Class\", records AS \"Records\",
                hectares AS \"Hectares\", percent AS \"% of region\"
         FROM unit_designations
         JOIN rules USING (designation)
         WHERE area = 'Whole region'
         ORDER BY CASE class WHEN 'no-go' THEN 1 WHEN 'consult' THEN 2 ELSE 3 END, designation"
  echo
  echo "## Registered battlefields and parks"
  echo
  echo "Both are non-statutory but highly sensitive. Consult Historic England and the"
  echo "local authority archaeologist before detecting on or near them."
  echo
  table "SELECT $link AS \"Name\", designation AS \"Designation\",
                round(ST_Area(ST_Intersection(d.geom, u.geom)) / 1e4, 1) AS \"Hectares in region\"
         FROM designations d, units u
         WHERE u.area = 'Whole region'
           AND d.designation IN ('Registered battlefield', 'Registered park and garden')
           AND ST_Intersects(d.geom, u.geom)
         ORDER BY designation, name"
  echo
  echo "## Notes"
  echo
  echo "- Scotland is not covered. Designations there are held by Historic Environment"
  echo "  Scotland and NatureScot, and finds law differs: all finds are reported under"
  echo "  Treasure Trove rather than the Treasure Act 1996."
  echo "- Berwick-upon-Tweed and the coast drain straight to the tidal Tweed or the sea,"
  echo "  so they lie outside the river catchments. Designations there are still"
  echo "  downloaded (\`STUDY_BBOX\` reaches the border), so an area there can be assessed."
  echo "- Terrain on the overview is a ${REGION_RELIEF_M} m hillshade. LiDAR at 1 m, where"
  echo "  earthworks become visible, is produced only for an assessed area."
  echo
  echo "This summary of public data is not legal advice. Check the current list entry"
  echo "before detecting."
} > "$REPORT"

echo "Wrote $REPORT"

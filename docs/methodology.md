# Methodology

This document describes how the pipeline turns a boundary file into a constraint
assessment, how the regional overview is built, the reasoning behind each
decision, and how the output was checked.

## 1. Scope

The unit of analysis is an area of interest (AOI): land where the landowner has
given permission to detect. The pipeline answers three questions about it:

1. Which parts are legally off limits?
2. Which parts need consent or advice before detecting?
3. What does the ground surface look like?

It deliberately does not answer "where are finds likely?". Predictive models of
find potential would point detecting toward unrecorded archaeology, which is the
opposite of the aim. Terrain products are cut to the AOI plus a 150 m margin for
the same reason.

The regional overview answers a different question: where do the statutory
designations lie across the border country and Coquetdale? It maps only records
that Historic England and Natural England already publish. Its terrain backdrop
is a 50 m hillshade, which shows hills and valleys; banks, ditches and
ridge-and-furrow only appear at around 1 m, and 1 m data is never processed for
the region as a whole.

## 2. Coordinate reference system

All analysis runs in British National Grid (EPSG:27700):

- The source data is published in it, so no reprojection is needed for analysis.
- Units are metres, so buffers, distances and areas need no conversion.
- Easting 400 000 is the projection's central meridian (2°W), which runs through
  the study area. Grid north and true north coincide there to within a small
  fraction of a degree.

Boundaries drawn in other systems (for example KML from Google Earth, which is
WGS84) are transformed on input. PROJ selects the OSTN15 grid transformation,
which EPSG rates at 1 m accuracy, against 2 m for the seven-parameter Helmert
fallback. That difference matters when the GPS margin is 10 m. The web map
reprojects vectors to WGS84 (EPSG:4326) and imagery to Web Mercator
(EPSG:3857), which Leaflet requires.

## 3. Study region

The region is the union of six Environment Agency Water Framework Directive
operational catchments, grouped into four areas in `region/catchments.csv`:
Tweed and Till, Coquetdale, Redesdale and Upper North Tynedale.

- **Why catchments.** "Coquetdale" is literally the valley of the Coquet, and
  the Northumberland border country is the land that drains off the Cheviot and
  border ridges to the Tweed, Rede and North Tyne. Published catchments give a
  boundary that is reproducible and physically meaningful, where a hand-drawn
  outline would be neither.
- **Construction.** `scripts/fetch_region.sh` downloads each catchment from the
  Catchment Data Explorer as GeoJSON. Each file holds the catchment's waterbody
  catchments (polygons) and river lines in WGS84; they are transformed to
  British National Grid with OSTN15. `sql/assess_region.sql` dissolves the
  waterbody polygons into catchments and areas with `ST_Union_Agg`. One
  interior ring, a sliver between neighbouring waterbodies near Kielder Water,
  is removed by rebuilding each part from its exterior ring.
- **Edges.** Berwick-upon-Tweed and the coast drain straight to the tidal Tweed
  or the sea, so they belong to no river catchment. `STUDY_BBOX` is drawn to the
  border, so designations there are still downloaded and an area there can
  still be assessed. It is only excluded from the regional statistics.
- **Scotland.** Historic England and Natural England data stops at the border,
  as does the Environment Agency LiDAR. Covering the Scottish side would need
  Historic Environment Scotland and NatureScot data and a different rules table:
  under Scots law all finds are reported through Treasure Trove.

## 4. Data acquisition

`scripts/fetch_designations.sh` queries the Historic England and Natural England
ArcGIS feature services with an envelope filter in EPSG:27700 and requests output
in EPSG:27700. GDAL's ESRIJSON driver reads the responses and pages through large
results. Two details:

- Each layer is written with an explicit geometry type, so a layer with no
  features in the study extent is still a valid, typed layer.
- An empty response carries no field definitions. The script rebuilds such a
  layer from a single sample feature, filtered out locally, so the SQL always
  sees the full schema.

LiDAR comes from the Environment Agency's Web Coverage Service (WCS 2.0.1) for
the LiDAR Composite DTM, through `scripts/fetch_dtm.sh`:

- Requests are split into chunks on a fixed grid, at most 1000 pixels and 10 km
  a side, because larger requests can come back with whole blocks missing.
  Chunks are fetched four at a time and cached in `data/dtm/<resolution>m/`, so
  repeat runs and neighbouring areas reuse them.
- Where the service holds no data (Scotland, open sea) it returns zeros without
  a NoData value, or HTTP 500 for resampled requests. Both are recorded as empty
  chunks, so they appear as NoData rather than as land at 0 m.
- The 1 m data is identical to the 5 km tiles on the Defra survey portal (see
  validation), so no manual download is needed.
- The regional backdrop is fetched at 25 m and averaged to 50 m. The service's
  own 50 m overviews carry a faint grid pattern that the averaging removes.

## 5. Constraint analysis

`scripts/assess_aoi.sh` first reprojects the boundary and checks that it, plus
the context radius, lies inside `STUDY_BBOX`. Outside it no designations were
downloaded, so the area would wrongly come back unconstrained; the script stops
instead.

`sql/assess_aoi.sql` runs in DuckDB with the spatial extension. The main steps:

1. **Rules table.** One row per designation type with its class (`no-go`,
   `consult`, `info`) and the legal or policy basis. Classification is a join
   against this table rather than logic spread through the queries.
2. **Unified designations.** Each source layer is mapped to a common schema
   (`designation`, `ref`, `name`, `url`, `geom`) with `UNION ALL`. Steps 1 and 2
   live in `sql/designations.sql`, which the AOI and regional analyses both
   `.read`, so the two cannot disagree about what a designation means.
3. **Nearby filter.** `ST_DWithin` keeps designations within the context radius
   of the AOI, recording distance and whether each one overlaps it.
4. **No-go areas.** For each scheduled monument, the part inside the AOI
   (`ST_Intersection`) and a margin ring
   (`ST_Difference(ST_Buffer(geom, margin), geom)`) clipped to the AOI.
5. **Available area.** The AOI minus the dissolved union of all no-go parts.
6. **Summary.** Areas are measured on dissolved geometries, so overlapping
   margins or designations are counted once.

DuckDB's `COPY ... (FORMAT GDAL)` writes one layer per file, so each output layer
is written as FlatGeobuf and the shell script merges them into a single
GeoPackage for QGIS. The database file keeps every intermediate table for ad hoc
queries.

### GPS margin

A scheduled monument boundary is a legal line, but a detectorist locates
themselves with a handheld or phone GNSS receiver. Under open sky these are
typically accurate to about 5 m. Accuracy falls under tree cover and beside steep
slopes. The 10 m default is roughly twice the open-sky figure. It is a setting in
`config.env`.

## 6. Regional summary

`sql/assess_region.sql` reuses the shared designations and adds:

1. **Units.** Each area and the whole region, ordered north to south.
2. **Dissolved designations.** One geometry per designation type, so
   overlapping records (for example SSSIs that share a boundary with access
   land) are measured once.
3. **Area by designation.** For each unit and designation, the number of
   records that touch it and the share of its land they cover. A record that
   crosses an area boundary counts in both areas but once for the region: 537
   scheduled monuments touch the four areas, 533 touch the region.
4. **Output layers.** Every record in the study extent, flagged `in_region`, so
   the maps can show context beyond the boundary without counting it.

## 7. Terrain

`scripts/build_terrain.sh` fetches the 1 m DTM for exactly the window it needs,
so boundaries that cross tile or chunk edges need no special handling.

1. Fetch the DTM for the AOI extent plus the display margin, plus a processing
   pad equal to the relief window plus 10 m.
2. Compute on the padded raster, then crop back. Filters and hillshading
   otherwise produce artefacts within a window's width of the edge.
3. **Multidirectional hillshade** (`gdaldem hillshade -multidirectional`). A
   single light source hides linear features that run parallel to it.
   Combining several azimuths avoids that bias.
4. **Slope** in degrees.
5. **Local relief model.** The DTM minus its focal mean over a 21 × 21 m window
   (`gdal raster neighbors`). Subtracting the smoothed surface removes
   hillside-scale landform and leaves micro-topography: banks, ditches,
   ridge-and-furrow and hut circles, with heights in metres rather than
   shading. The map stretches the result from −0.5 m to +0.5 m.
6. **Zonal statistics** (`gdal raster zonal-stats`) give elevation and slope
   inside the exact AOI polygon rather than its bounding box.

The relief model is a simplified form of Hesse (2010), which also purges the
smoothed surface using zero-relief contours. The simplification can exaggerate
relief at sharp breaks of slope, such as stream banks.

## 8. Cartography

- Constraint classes use a fixed status palette (red no-go, amber consult, green
  available). Hatching also distinguishes them, so classes do not depend on
  colour alone. This matters for colour-vision deficiency and greyscale print.
- The relief model uses a diverging blue–grey–red ramp centred on zero, with
  neutral grey for no relief.
- Land outside the AOI is washed out to keep the focus on the permission. The
  wash is a frame with the AOI cut out of it; the frame is wound opposite to the
  polygon so that the nonzero fill rule leaves a hole.
- The regional map applies the same wash outside the region, labels the
  registered battlefields by name and year, and shows Scotland and the sea as a
  flat neutral because they have no data.
- On the regional web map, scheduled monuments are drawn as dots below zoom 13
  so that small sites remain visible, and as outlines above it. The hillshade is
  rescaled so level ground is white and drawn with multiply blending, so it
  shades hills without greying the base map.
- Labels are National Heritage List entry numbers, which link unambiguously to
  the official record. Names can be long and are not unique.

## 9. Validation

**Areas against the published figures.** Historic England publishes an
`area_ha` value for each scheduled monument. For the 566 monuments in the study
extent larger than 0.05 ha, the median ratio of computed area to published area
is 0.999204, and 90% of ratios lie between 0.99920 and 0.99922. The square of
the British National Grid central scale factor (0.9996012717²) is 0.999203. The
0.08% difference is therefore the projection's scale distortion: the pipeline
reports grid areas, and Historic England's figures are ground areas. The small
spread is expected, because the scale factor grows slightly with distance from
the central meridian. This confirms that geometries, CRS handling and area
calculation are consistent with the publisher's.

**Demo area.** 230.3 ha containing four scheduled monuments (an Iron Age hillfort,
an enclosure, a defended settlement and a camp). 5.7 ha falls within scheduled
extents and 1.7 ha within the 10 m margin, leaving 222.9 ha (96.8%) available.
The Ingram Farm scheduled area is reported 123 m outside the boundary. Each
monument's area inside the AOI matches its published area, as expected for
monuments wholly inside.

**LiDAR service against the downloaded tiles.** The demo area was processed
once from the four 5 km tiles downloaded from the Defra portal and once from the
coverage service. All four products (DTM, hillshade, slope and local relief
model) have the same grid and a maximum absolute difference of 0.0, and the
reports match line for line.

**Regional downloads.** Feature counts for the study extent match the services'
own `returnCountOnly` totals: 797 scheduled monuments, 3,550 listed buildings,
62 SSSIs, 1,210 open access polygons, 14 registered parks and gardens and 4
registered battlefields (Flodden, Halidon Hill, Homildon Hill and Otterburn).
The four areas sum to the region's 2,055.7 km², so the dissolve neither loses
nor double-counts land.

**Input formats.** A test boundary across the River Coquet at Rothbury, supplied
as WGS84 KML, was reprojected and assessed correctly. The output identified the
River Coquet and Coquet Valley Woodlands SSSI (consult), Rothbury Bridge
(scheduled, no-go) and 48 listed buildings within 250 m.

**Performance.** On an Apple silicon laptop the demo area runs end to end, from
boundary to report, in about 15 seconds including the LiDAR fetch. The regional
overview takes under a minute on first run, most of it fetching the backdrop.

## 10. Extensions consistent with the design

- Split the AOI into fields using OS Open Zoomstack or MasterMap boundaries and
  report available area per field.
- Check recorded GPX tracks from detecting sessions against the no-go layer, as
  a compliance check after the fact.
- Add Northumberland Historic Environment Record (HER) data where a licence
  allows, as context for the landowner rather than as targets.
- Extend across the border with Historic Environment Scotland and NatureScot
  data and a Scottish rules table.
- Query the feature services for each AOI at run time instead of from a
  snapshot, so every assessment uses the live list.

## References

- Ancient Monuments and Archaeological Areas Act 1979, s.42.
- Countryside and Rights of Way Act 2000, Schedule 2.
- Treasure Act 1996.
- Hesse, R. (2010). LiDAR-derived Local Relief Models: a new tool for
  archaeological prospection. *Archaeological Prospection* 17(2), 67–72.
- Historic England (2018). *Using Airborne Lidar in Archaeological Survey: The
  Light Fantastic*. Swindon: Historic England.
- *Code of Practice for Responsible Metal Detecting in England and Wales* (2017).

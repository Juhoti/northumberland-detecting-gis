# Northumberland Detecting GIS

A reproducible GIS pipeline that checks a parcel of land against statutory heritage
and environmental designations before metal detecting. It covers the Northumberland
border country and Coquetdale, combines open data from Historic England, Natural
England and the Environment Agency, and is built with GDAL, DuckDB spatial SQL and
Python.

![Regional overview of designations](docs/example/overview.png)

Example output: [regional overview](docs/example/region_report.md) ·
[regional web map](https://juhoti.github.io/northumberland-detecting-gis/region/) ·
[constraint report for a demo area](docs/example/report.md) ·
[local relief model](docs/example/relief.jpg) ·
[demo area web map](https://juhoti.github.io/northumberland-detecting-gis/map/)

## Design principle

The pipeline is permission-first, not discovery-first. The input is a boundary of
land where the landowner has given permission. The output is the known legal
constraints on that land and the terrain context. It does not search for
undiscovered sites, rank land by find potential, or publish predicted findspots.

LiDAR at 1 m, the resolution at which earthworks become visible, is processed only
for the area of interest and a small margin around it, never for the wider
landscape. The regional overview uses a 50 m hillshade, which shows hills and
valleys but not archaeology, and maps only designations that are already public.

Real permission boundaries identify land and landowners. They belong in
`aoi/private/`, which git ignores. The committed example in `aoi/examples/` is an
arbitrary polygon drawn for demonstration. It is not a real permission. Maps and
web pages only ever draw boundaries from `aoi/examples/`.

## Study region

The region is defined from Environment Agency Water Framework Directive
operational catchments, listed in [`region/catchments.csv`](region/catchments.csv):

| Area | Catchments | km² |
|---|---|---:|
| Tweed and Till | Tweed River, Till River | 633 |
| Coquetdale | Coquet Upper, Coquet Lower | 597 |
| Redesdale | Rede | 347 |
| Upper North Tynedale | North Tyne Upper | 478 |

The border country is the land that drains to the Tweed (through the Till), the
Rede and the upper North Tyne. Coquetdale is the Coquet catchment from its source
on the border to the tidal limit at Warkworth. Using published catchments rather
than a hand-drawn outline makes the region reproducible and gives each area a
physical meaning.

Designations are downloaded for `STUDY_BBOX`, which covers the region and runs
north to the border. Any boundary inside that box can be assessed, including
Berwick-upon-Tweed, which drains straight into the tidal Tweed and so lies outside
the river catchments. A boundary that extends beyond the box is refused rather
than reported as unconstrained.

Scotland is not covered. Its designations are held by Historic Environment
Scotland and NatureScot, and Scots law on finds differs.

## What it produces

For one area of interest (AOI), `make` writes to `output/<name>/`:

| File | Contents |
|---|---|
| `<name>.gpkg` | GeoPackage with layers `aoi`, `available`, `no_go`, `consult`, `scheduled_nearby` and `listed_nearby`, ready for QGIS |
| `constraints.png` | Map of no-go areas, consult areas and nearby records over a hillshade |
| `relief.jpg` | Local relief model with scheduled monuments outlined |
| `report.md` | Area summary, linked list entries, guidance and terrain statistics |
| `terrain/` | 1 m DTM, multidirectional hillshade, slope and local relief model GeoTIFFs |
| `assessment.duckdb` | Every intermediate table, for ad hoc SQL |

For the region, `make region` writes to `output/region/`:

| File | Contents |
|---|---|
| `region.gpkg` | Region, areas, catchments, rivers and every designation in the study extent |
| `overview.png` | Regional map of designations over a 50 m hillshade |
| `report.md` | Designations by area and for the whole region, with battlefields and parks |
| `region.duckdb` | Every intermediate table, for ad hoc SQL |

Constraint classes:

| Class | Designations | Treatment |
|---|---|---|
| No-go | Scheduled monuments | Removed from the available area, with a GPS margin. Detecting without consent is an offence under s.42 of the Ancient Monuments and Archaeological Areas Act 1979. |
| Consult | SSSIs, registered parks and gardens, registered battlefields, World Heritage Sites | Kept in the available area but flagged, with guidance on who to consult |
| Information | CRoW Act 2000 open access land | Flagged: the public right of access excludes metal detecting, so detecting relies on the landowner's permission |
| Context | Listed buildings within the search radius | Listed in the report and shown on the map |

## Data sources

| Dataset | Publisher | Access | Licence |
|---|---|---|---|
| LiDAR Composite DTM, 1 m | Environment Agency | Web Coverage Service, fetched for each window and cached | OGL v3.0 |
| National Heritage List for England | Historic England | ArcGIS feature service, queried by bounding box | OGL v3.0 |
| Sites of Special Scientific Interest | Natural England | ArcGIS feature service | OGL v3.0 |
| CRoW Act 2000 Section 4 open country | Natural England | ArcGIS feature service | OGL v3.0 |
| WFD operational catchments and rivers | Environment Agency | Catchment Data Explorer, GeoJSON | OGL v3.0 |
| Place label positions | OpenStreetMap contributors | Recorded once in `region/places.csv` | ODbL |

All data is processed in British National Grid (EPSG:27700), so distances and
areas are in metres. Boundaries supplied in other coordinate systems are
transformed with the OSTN15 grid.

## Requirements

- GDAL 3.12 or later, for `gdal raster neighbors` and `gdal raster zonal-stats`
- DuckDB 1.4 or later, with the spatial extension
- Python 3 with NumPy, Matplotlib and the GDAL bindings
- An internet connection on first use; downloads are cached in `data/`

On macOS:

```sh
brew install gdal duckdb numpy python-matplotlib
```

## Usage

```sh
make                                  # assess the AOI named in config.env
make AOI=aoi/private/north_field.kml  # assess another boundary
make web                              # rebuild docs/map from the current AOI
make region                           # regional overview in output/region
make region-web                       # rebuild docs/region
make refresh                          # download designations and catchments again
```

Designations, catchments and LiDAR are downloaded on first use. The boundary can
be any vector format GDAL reads (GeoJSON, GeoPackage, KML from Google Earth,
shapefile) in any coordinate system. The demo area runs end to end in about 15
seconds, and the regional overview in under a minute.

Settings in `config.env`:

| Variable | Default | Meaning |
|---|---|---|
| `STUDY_BBOX` | `354000,576000,426000,658000` | Extent for downloading designations (EPSG:27700) |
| `AOI` | `aoi/examples/demo_area.geojson` | Boundary processed by `make` |
| `GPS_MARGIN_M` | `10` | Buffer around scheduled monuments to absorb handheld GPS error |
| `CONTEXT_RADIUS_M` | `250` | Radius for listing nearby monuments and listed buildings |
| `TERRAIN_BUFFER_M` | `150` | Margin around the AOI for terrain products |
| `LRM_WINDOW_M` | `20` | Focal mean window for the local relief model |
| `REGION_RELIEF_M` | `50` | Resolution of the regional hillshade |

## Repository layout

```
config.env                    settings
Makefile                      pipeline
region/
  catchments.csv              catchments that make up the region, grouped into areas
  places.csv                  label positions for the overview map
scripts/
  fetch_designations.sh       download designations from the ArcGIS REST services
  fetch_region.sh             download the catchments that define the region
  fetch_dtm.sh                fetch EA LiDAR for a window from the WCS, with a cache
  assess_aoi.sh               normalise the boundary, run the SQL, build the GeoPackage
  build_terrain.sh            hillshade, slope, local relief model, statistics
  render_maps.py              static maps for an AOI
  write_report.sh             Markdown report for an AOI
  export_web.py               reproject layers and imagery for the AOI web map
  assess_region.sh            regional SQL, GeoPackage and terrain backdrop
  render_region.py            regional overview map
  write_region_report.sh      Markdown report for the region
  export_region_web.py        layers and imagery for the regional web map
sql/
  designations.sql            designations in one schema, and the rules table
  assess_aoi.sql              spatial analysis for an AOI
  assess_region.sql           designations summarised by area
aoi/examples/                 demo boundary
docs/methodology.md           method, decisions and limitations
docs/example/                 output for the demo area and the region
docs/map/                     Leaflet web map for the demo area
docs/region/                  Leaflet web map for the region
```

## Method

See [docs/methodology.md](docs/methodology.md) for the processing steps, the
reasoning behind the region, the GPS margin and the relief model, and validation.

## Limitations

- Designations are a snapshot. List entries are added, amended and removed, so
  check the live entry before detecting.
- Scheduled monument boundaries were captured at a range of map scales (recorded
  in the `CaptureScale` field). The GPS margin absorbs some of that uncertainty but
  not all of it.
- Non-designated sites in the Northumberland Historic Environment Record are not
  included. The HER should be consulted directly.
- Scotland is not covered, and the region follows river catchments, so the coast
  and Berwick-upon-Tweed sit outside the regional statistics (though inside the
  assessable extent).
- Terrain depends on the Environment Agency coverage service being available.
  Fetched chunks are cached in `data/dtm/`.
- The local relief model is a simplified trend removal (DTM minus focal mean),
  not the full method of Hesse (2010).
- The output summarises public data and is not legal advice. Responsible
  detecting also follows the Code of Practice for Responsible Metal Detecting in
  England and Wales, the Treasure Act 1996 and recording with the Portable
  Antiquities Scheme.

## Licence

Code is released under the MIT Licence. Data attribution:

- © Environment Agency copyright and/or database right. All rights reserved.
- © Historic England 2026. Contains Ordnance Survey data © Crown copyright and
  database right 2026.
- © Natural England 2026. Contains Ordnance Survey data © Crown copyright and
  database right 2026.
- Place label positions © OpenStreetMap contributors, under the Open Database
  Licence.

Environment Agency, Historic England and Natural England data is used under the
Open Government Licence v3.0.

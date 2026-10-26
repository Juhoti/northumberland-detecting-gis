-- Statutory designations summarised across the study region.
--
-- Run through scripts/assess_region.sh, which sets these variables first:
--   designations     GeoPackage written by scripts/fetch_designations.sh
--   catchments       GeoPackage written by scripts/fetch_region.sh
--   catchment_table  region/catchments.csv: catchment id, name and area
--   layers_dir       directory for the output FlatGeobuf layers
--
-- The overview describes where designations are, not where to detect. Every
-- figure is public statutory data summarised by area.

LOAD spatial;
SET geometry_always_xy = true;

-- Tables `rules` and `designations`.
.read sql/designations.sql


-- Region -----------------------------------------------------------------------
-- Waterbody catchments dissolve into their operational catchment, and those into
-- the named areas of the catchment table.

CREATE OR REPLACE TABLE catchments AS
SELECT c.area, c.catchment, c.catchment_id, ST_Union_Agg(w.geom) AS geom
FROM read_csv(getvariable('catchment_table')) c
JOIN ST_Read(getvariable('catchments'), layer = 'waterbodies') w USING (catchment_id)
GROUP BY ALL;

-- Each area, then the whole region, numbered north to south. Interior rings are
-- dropped: they are slivers between neighbouring waterbody polygons, not land
-- outside the region.
CREATE OR REPLACE TABLE units AS
WITH parts AS (
    SELECT area, unnest(ST_Dump(ST_Union_Agg(geom)), recursive := true)
    FROM catchments
    GROUP BY area
),
areas AS (
    SELECT area, ST_Union_Agg(ST_MakePolygon(ST_ExteriorRing(geom))) AS geom
    FROM parts
    GROUP BY area
)
SELECT row_number() OVER (ORDER BY ST_Y(ST_Centroid(geom)) DESC) AS ord,
       area, ST_Area(geom) AS m2, geom
FROM areas
UNION ALL
SELECT (SELECT count(*) FROM areas) + 1, 'Whole region', ST_Area(geom), geom
FROM (SELECT ST_Union_Agg(geom) AS geom FROM areas);

CREATE OR REPLACE TABLE rivers AS
SELECT r.name, c.area, r.geom
FROM ST_Read(getvariable('catchments'), layer = 'rivers') r
JOIN read_csv(getvariable('catchment_table')) c USING (catchment_id);


-- Designations by area ---------------------------------------------------------

CREATE OR REPLACE TABLE listed_buildings AS
SELECT ListEntry::VARCHAR AS ref, Name AS name, Grade AS grade, hyperlink AS url, geom
FROM ST_Read(getvariable('designations'), layer = 'listed_buildings');

-- Each designation dissolved, so overlapping records are measured once.
CREATE OR REPLACE TABLE dissolved AS
SELECT designation, ST_Union_Agg(geom) AS geom
FROM designations
GROUP BY designation;

-- One row per area and designation: records that touch the area, and the share
-- of its land they cover. A record crossing an area boundary counts in both
-- areas but once for the whole region.
CREATE OR REPLACE TABLE unit_designations AS
SELECT u.ord, u.area, d.designation,
       (SELECT count(*) FROM designations x
        WHERE x.designation = d.designation AND ST_Intersects(x.geom, u.geom)) AS records,
       round(ST_Area(ST_Intersection(u.geom, d.geom)) / 1e4, 1) AS hectares,
       round(100 * ST_Area(ST_Intersection(u.geom, d.geom)) / u.m2, 2) AS percent
FROM units u, dissolved d;

CREATE OR REPLACE TABLE summary AS
WITH listed AS (
    SELECT u.area, count(l.ref) AS n
    FROM units u
    LEFT JOIN listed_buildings l ON ST_Intersects(l.geom, u.geom)
    GROUP BY u.area
)
SELECT u.area,
       round(u.m2 / 1e6, 1) AS area_km2,
       max(d.records) FILTER (d.designation = 'Scheduled monument') AS scheduled_monuments,
       max(d.percent) FILTER (d.designation = 'Scheduled monument') AS scheduled_pct,
       any_value(l.n) AS listed_buildings,
       max(d.records) FILTER (d.designation = 'SSSI') AS sssis,
       round(max(d.percent) FILTER (d.designation = 'SSSI'), 1) AS sssi_pct,
       round(max(d.percent) FILTER (d.designation = 'CRoW access land'), 1) AS access_pct
FROM units u
JOIN unit_designations d USING (area)
JOIN listed l USING (area)
GROUP BY u.ord, u.area, u.m2
ORDER BY u.ord;


-- Output layers ----------------------------------------------------------------
-- Records cover the whole study extent; in_region marks those that touch the
-- region, so the map can show context beyond it.

CREATE OR REPLACE TEMP TABLE region AS
SELECT geom FROM units WHERE area = 'Whole region';

COPY (SELECT round(m2 / 1e6, 1) AS area_km2, ST_Multi(geom) AS geom FROM units
      WHERE area = 'Whole region')
TO (getvariable('layers_dir') || '/region.fgb')
WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:27700', GEOMETRY_TYPE 'MULTIPOLYGON');

COPY (SELECT ord, area, round(m2 / 1e6, 1) AS area_km2, ST_Multi(geom) AS geom
      FROM units WHERE area <> 'Whole region')
TO (getvariable('layers_dir') || '/areas.fgb')
WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:27700', GEOMETRY_TYPE 'MULTIPOLYGON');

COPY (SELECT area, catchment, catchment_id, round(ST_Area(geom) / 1e6, 1) AS area_km2,
             ST_Multi(geom) AS geom
      FROM catchments)
TO (getvariable('layers_dir') || '/catchments.fgb')
WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:27700', GEOMETRY_TYPE 'MULTIPOLYGON');

COPY (SELECT name, area, ST_Multi(geom) AS geom FROM rivers)
TO (getvariable('layers_dir') || '/rivers.fgb')
WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:27700', GEOMETRY_TYPE 'MULTILINESTRING');

COPY (SELECT ST_Multi(ST_CollectionExtract(geom, 3)) AS geom
      FROM dissolved WHERE designation = 'CRoW access land')
TO (getvariable('layers_dir') || '/open_access.fgb')
WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:27700', GEOMETRY_TYPE 'MULTIPOLYGON');

COPY (SELECT d.designation, d.ref, d.name, d.url, guidance, round(ST_Area(d.geom) / 1e4, 2) AS area_ha,
             ST_Intersects(d.geom, r.geom) AS in_region, ST_Multi(d.geom) AS geom
      FROM designations d JOIN rules USING (designation), region r
      WHERE class = 'consult')
TO (getvariable('layers_dir') || '/consult.fgb')
WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:27700', GEOMETRY_TYPE 'MULTIPOLYGON');

COPY (SELECT d.ref, d.name, d.url, round(ST_Area(d.geom) / 1e4, 2) AS area_ha,
             ST_Intersects(d.geom, r.geom) AS in_region, ST_Multi(d.geom) AS geom
      FROM designations d, region r
      WHERE d.designation = 'Scheduled monument')
TO (getvariable('layers_dir') || '/scheduled_monuments.fgb')
WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:27700', GEOMETRY_TYPE 'MULTIPOLYGON');

COPY (SELECT l.ref, l.name, l.grade, l.url, ST_Intersects(l.geom, r.geom) AS in_region,
             ST_Multi(l.geom) AS geom
      FROM listed_buildings l, region r)
TO (getvariable('layers_dir') || '/listed_buildings.fgb')
WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:27700', GEOMETRY_TYPE 'MULTIPOINT');

FROM summary;

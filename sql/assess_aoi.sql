-- Permission-first constraint assessment for one area of interest (AOI).
--
-- Run through scripts/assess_aoi.sh, which sets these variables first:
--   aoi_path          AOI boundary, already reprojected to EPSG:27700
--   designations      GeoPackage written by scripts/fetch_designations.sh
--   layers_dir        directory for the output FlatGeobuf layers
--   gps_margin_m      buffer added around scheduled monuments for GPS error
--   context_radius_m  search radius for records near the AOI
--
-- All data is in British National Grid, so distances are metres and areas m².

LOAD spatial;
SET geometry_always_xy = true;

-- Tables `rules` and `designations`.
.read sql/designations.sql


-- Inputs ---------------------------------------------------------------------

-- The AOI may arrive as several parcels; treat it as one geometry.
CREATE OR REPLACE TABLE aoi AS
SELECT ST_Union_Agg(geom) AS geom
FROM ST_Read(getvariable('aoi_path'));


-- Designations near the AOI ------------------------------------------------------

CREATE OR REPLACE TABLE nearby AS
SELECT d.designation, d.ref, d.name, d.url, r.class, r.guidance,
       round(ST_Distance(d.geom, a.geom), 1) AS distance_m,
       ST_Intersects(d.geom, a.geom) AS overlaps_aoi,
       d.geom
FROM designations d
JOIN rules r USING (designation)
CROSS JOIN aoi a
WHERE ST_DWithin(d.geom, a.geom, getvariable('context_radius_m'));


-- No-go areas ----------------------------------------------------------------
-- The legal extent of each scheduled monument inside the AOI, plus a margin ring
-- around it so a handheld GPS reading near the boundary still falls outside.

CREATE OR REPLACE TABLE no_go AS
WITH parts AS (
    SELECT n.ref, n.name, n.url, 'scheduled area' AS kind,
           ST_Intersection(n.geom, a.geom) AS geom
    FROM nearby n, aoi a
    WHERE n.class = 'no-go' AND n.overlaps_aoi
    UNION ALL
    SELECT n.ref, n.name, n.url, 'GPS margin' AS kind,
           ST_Intersection(
               ST_Difference(ST_Buffer(n.geom, getvariable('gps_margin_m')), n.geom),
               a.geom) AS geom
    FROM nearby n, aoi a
    WHERE n.class = 'no-go' AND n.distance_m <= getvariable('gps_margin_m')
)
SELECT ref, name, url, kind,
       round(ST_Area(geom) / 1e4, 3) AS area_ha,
       ST_Multi(ST_CollectionExtract(geom, 3)) AS geom
FROM parts
WHERE ST_Area(geom) > 0;


-- Consult and info areas -------------------------------------------------------

CREATE OR REPLACE TABLE consult AS
WITH parts AS (
    SELECT n.designation, n.ref, n.name, n.url, n.class, n.guidance,
           ST_Intersection(n.geom, a.geom) AS geom
    FROM nearby n, aoi a
    WHERE n.class IN ('consult', 'info') AND n.overlaps_aoi
)
SELECT designation, ref, name, url, class, guidance,
       round(ST_Area(geom) / 1e4, 3) AS area_ha,
       ST_Multi(ST_CollectionExtract(geom, 3)) AS geom
FROM parts
WHERE ST_Area(geom) > 0;


-- Available area -------------------------------------------------------------
-- The AOI minus every no-go part. Consult areas stay in, flagged separately.

CREATE OR REPLACE TABLE available AS
SELECT ST_Multi(ST_CollectionExtract(
           CASE WHEN x.geom IS NULL THEN a.geom ELSE ST_Difference(a.geom, x.geom) END,
           3)) AS geom
FROM aoi a, (SELECT ST_Union_Agg(geom) AS geom FROM no_go) x;


-- Nearby listed buildings --------------------------------------------------------
-- Context only: a listed building does not restrict detecting by itself, but it
-- marks historic settlement close to the land.

CREATE OR REPLACE TABLE listed_nearby AS
SELECT lb.ListEntry::VARCHAR AS ref, lb.Name AS name, lb.Grade AS grade, lb.hyperlink AS url,
       round(ST_Distance(lb.geom, a.geom), 1) AS distance_m,
       lb.geom
FROM ST_Read(getvariable('designations'), layer = 'listed_buildings') lb, aoi a
WHERE ST_DWithin(lb.geom, a.geom, getvariable('context_radius_m'));


-- Summary --------------------------------------------------------------------
-- Areas come from dissolved geometries, so overlapping parts are counted once.

CREATE OR REPLACE TABLE summary AS
WITH a AS (SELECT ST_Area(geom) AS m2 FROM aoi),
     areas AS (
         SELECT 1 AS ord, 'Area of interest' AS measure, (SELECT m2 FROM a) AS m2
         UNION ALL
         SELECT 2, 'Scheduled monuments (legal extent)',
                coalesce(ST_Area(ST_Union_Agg(geom)), 0) FROM no_go WHERE kind = 'scheduled area'
         UNION ALL
         SELECT 3, 'GPS margin (' || getvariable('gps_margin_m') || ' m)',
                coalesce(ST_Area(ST_Union_Agg(geom)), 0) FROM no_go WHERE kind = 'GPS margin'
         UNION ALL
         SELECT 4, 'Consult before detecting',
                coalesce(ST_Area(ST_Union_Agg(geom)), 0) FROM consult WHERE class = 'consult'
         UNION ALL
         SELECT 5, 'Open access land (information only)',
                coalesce(ST_Area(ST_Union_Agg(geom)), 0) FROM consult WHERE class = 'info'
         UNION ALL
         SELECT 6, 'Available for detecting', ST_Area(geom) FROM available
     )
SELECT measure,
       round(m2 / 1e4, 2) AS hectares,
       round(100 * m2 / (SELECT m2 FROM a), 1) AS percent
FROM areas
ORDER BY ord;


-- Output layers ----------------------------------------------------------------

COPY (SELECT round(ST_Area(geom) / 1e4, 2) AS area_ha, ST_Multi(geom) AS geom FROM aoi)
TO (getvariable('layers_dir') || '/aoi.fgb')
WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:27700', GEOMETRY_TYPE 'MULTIPOLYGON');

COPY (SELECT * FROM no_go)
TO (getvariable('layers_dir') || '/no_go.fgb')
WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:27700', GEOMETRY_TYPE 'MULTIPOLYGON');

COPY (SELECT * FROM consult)
TO (getvariable('layers_dir') || '/consult.fgb')
WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:27700', GEOMETRY_TYPE 'MULTIPOLYGON');

COPY (SELECT round(ST_Area(geom) / 1e4, 2) AS area_ha, geom FROM available)
TO (getvariable('layers_dir') || '/available.fgb')
WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:27700', GEOMETRY_TYPE 'MULTIPOLYGON');

COPY (SELECT ref, name, url, distance_m, overlaps_aoi, ST_Multi(geom) AS geom
      FROM nearby WHERE designation = 'Scheduled monument')
TO (getvariable('layers_dir') || '/scheduled_nearby.fgb')
WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:27700', GEOMETRY_TYPE 'MULTIPOLYGON');

COPY (SELECT * FROM listed_nearby)
TO (getvariable('layers_dir') || '/listed_nearby.fgb')
WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:27700', GEOMETRY_TYPE 'MULTIPOINT');

FROM summary;

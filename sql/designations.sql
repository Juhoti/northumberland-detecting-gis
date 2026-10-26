-- Statutory designations in one schema, and the rules that classify them.
--
-- Shared by assess_aoi.sql and assess_region.sql through `.read`. Expects the
-- variable `designations`: the GeoPackage written by scripts/fetch_designations.sh.

-- Rules ----------------------------------------------------------------------
-- How each designation constrains metal detecting, and the basis for it.
--   no-go    detecting is an offence without consent; excluded from the AOI
--   consult  not prohibited, but consent or advice is needed first
--   info     affects access rights rather than permission-based detecting

CREATE OR REPLACE TABLE rules (designation VARCHAR, class VARCHAR, guidance VARCHAR);
INSERT INTO rules VALUES
    ('Scheduled monument', 'no-go',
     'Using a metal detector on a scheduled monument without written consent from Historic England is an offence (Ancient Monuments and Archaeological Areas Act 1979, s.42).'),
    ('World Heritage Site', 'consult',
     'Internationally designated landscape. Check the site management plan and consult the local authority archaeologist.'),
    ('Registered battlefield', 'consult',
     'Non-statutory but highly sensitive: finds lose their evidential value once moved. Consult Historic England and the local authority archaeologist.'),
    ('Registered park and garden', 'consult',
     'Non-statutory designation that may include buried garden features. Consult the local authority archaeologist.'),
    ('SSSI', 'consult',
     'Activities on the site''s list of operations requiring Natural England''s consent may include ground disturbance. Check the list and obtain consent where needed.'),
    ('CRoW access land', 'info',
     'The public right of access excludes metal detecting (Countryside and Rights of Way Act 2000, Sch. 2). Detecting relies on the landowner''s permission, not access rights.');


-- Designations ---------------------------------------------------------------
-- Area designations from both publishers, in one schema.
CREATE OR REPLACE TABLE designations AS
SELECT 'Scheduled monument' AS designation, ListEntry::VARCHAR AS ref, Name AS name,
       hyperlink AS url, geom
FROM ST_Read(getvariable('designations'), layer = 'scheduled_monuments')
UNION ALL
SELECT 'World Heritage Site', ListEntry::VARCHAR, Name, hyperlink, geom
FROM ST_Read(getvariable('designations'), layer = 'world_heritage_sites')
UNION ALL
SELECT 'Registered battlefield', ListEntry::VARCHAR, Name, hyperlink, geom
FROM ST_Read(getvariable('designations'), layer = 'battlefields')
UNION ALL
SELECT 'Registered park and garden', ListEntry::VARCHAR, Name || ' (Grade ' || Grade || ')',
       hyperlink, geom
FROM ST_Read(getvariable('designations'), layer = 'parks_and_gardens')
UNION ALL
SELECT 'SSSI', REF_CODE, NAME,
       'https://designatedsites.naturalengland.org.uk/SiteDetail.aspx?SiteCode=S' || HYPERLINK, geom
FROM ST_Read(getvariable('designations'), layer = 'sssi')
UNION ALL
SELECT 'CRoW access land', NULL, 'Section 4 open country', NULL, geom
FROM ST_Read(getvariable('designations'), layer = 'crow_open_country');

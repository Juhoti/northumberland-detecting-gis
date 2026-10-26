"""Export the regional overview for the Leaflet web map.

Usage: python3 scripts/export_region_web.py output/region docs/region

Writes into the destination directory:
  data.js        layers (WGS84 GeoJSON, simplified), summary tables, area label
                 positions and image bounds
  hillshade.jpg  regional hillshade as shading, Web Mercator

The page draws the hillshade with multiply blending. It is rescaled so that
level ground and areas without data are white, which leaves the base map
unchanged there, and only slopes in shadow darken it.
"""

import csv
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from osgeo import gdal, osr

sys.path.insert(0, str(Path(__file__).resolve().parent))
from export_web import geojson, to_web_jpeg  # noqa: E402
from render_maps import read_config  # noqa: E402

gdal.UseExceptions()

ROOT = Path(__file__).resolve().parent.parent

# Layer name and simplification tolerance in metres. Tolerances stay below what
# is visible at the zoom each layer is used at.
LAYERS = {
    "region": 10,
    "areas": 10,
    "rivers": 10,
    "open_access": 10,
    "consult": 5,
    "scheduled_monuments": 1,
    "listed_buildings": 0,
}


def query(db, sql):
    result = subprocess.run(["duckdb", "-readonly", "-json", str(db), "-c", sql],
                            check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def shading(src, tmp):
    """Hillshade rescaled for multiply blending: flat ground and NoData become
    white, so only slopes facing away from the light darken the base map."""
    ds = gdal.Open(str(src))
    band = ds.GetRasterBand(1)
    hillshade = band.ReadAsArray().astype("float32")
    values, counts = np.unique(hillshade[hillshade > 0], return_counts=True)
    flat = values[counts.argmax()]   # the commonest value is level ground
    shade = 255 * np.clip(hillshade / flat, 0, 1) ** 2
    shade[hillshade == (band.GetNoDataValue() or 0)] = 255
    path = Path(tmp) / "shading.tif"
    out = gdal.GetDriverByName("GTiff").Create(str(path), ds.RasterXSize, ds.RasterYSize, 1,
                                               gdal.GDT_Byte)
    out.SetGeoTransform(ds.GetGeoTransform())
    out.SetProjection(ds.GetProjection())
    out.GetRasterBand(1).WriteArray(shade.astype(np.uint8))
    out = None
    return path


def polygons_only(collection):
    """Simplification can collapse a sliver of a polygon into a point inside a
    GeometryCollection. Keep only the polygon parts."""
    for feature in collection["features"]:
        geometry = feature["geometry"]
        if geometry and geometry["type"] == "GeometryCollection":
            parts = []
            for part in geometry["geometries"]:
                if part["type"] == "Polygon":
                    parts.append(part["coordinates"])
                elif part["type"] == "MultiPolygon":
                    parts.extend(part["coordinates"])
            feature["geometry"] = {"type": "MultiPolygon", "coordinates": parts}
    return collection


def area_labels():
    """Area label positions from region/places.csv, as [name, lat, lon]."""
    bng, wgs84 = osr.SpatialReference(), osr.SpatialReference()
    bng.ImportFromEPSG(27700)
    wgs84.ImportFromEPSG(4326)
    wgs84.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
    transform = osr.CoordinateTransformation(bng, wgs84)
    labels = []
    with open(ROOT / "region" / "places.csv", newline="") as f:
        for place in csv.DictReader(f):
            if place["kind"] == "area":
                lon, lat, _ = transform.TransformPoint(float(place["easting"]),
                                                       float(place["northing"]))
                labels.append([place["name"], round(lat, 5), round(lon, 5)])
    return labels


def examples(tmp):
    """Committed example boundaries only, never private permissions."""
    features = []
    for path in sorted((ROOT / "aoi" / "examples").glob("*.geojson")):
        features += geojson(path, path.stem, tmp)["features"]
    return {"type": "FeatureCollection", "features": features}


def main():
    out, dest = Path(sys.argv[1]), Path(sys.argv[2])
    dest.mkdir(parents=True, exist_ok=True)
    db = out / "region.duckdb"
    config = read_config(ROOT / "config.env")

    with tempfile.TemporaryDirectory() as tmp:
        data = {
            "layers": {layer: polygons_only(geojson(out / "region.gpkg", layer, tmp, precision=5,
                                                    simplify_m=tolerance))
                       for layer, tolerance in LAYERS.items()},
            "summary": query(db, "FROM summary"),
            "designations": query(db, """
                SELECT designation, records, hectares, percent FROM unit_designations
                WHERE area = 'Whole region' ORDER BY percent DESC"""),
            "labels": area_labels(),
            "params": {"region_relief_m": int(config["REGION_RELIEF_M"])},
            "images": {
                "hillshade": to_web_jpeg(shading(out / "hillshade.tif", tmp),
                                         dest / "hillshade.jpg", tmp, pixel_m=80, fill=255),
            },
        }
        data["layers"]["examples"] = examples(tmp)

    (dest / "data.js").write_text("window.REGION_DATA = " + json.dumps(data, separators=(",", ":")) + ";\n")
    print(f"Wrote {dest}/data.js and hillshade.jpg")


if __name__ == "__main__":
    main()

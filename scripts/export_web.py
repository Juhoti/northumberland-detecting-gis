"""Export one assessed area of interest for the Leaflet web map.

Usage: python3 scripts/export_web.py output/<name> docs/map

Writes into the destination directory:
  data.js        vector layers (WGS84 GeoJSON), summary table and image bounds
  hillshade.jpg  multidirectional hillshade, Web Mercator
  relief.jpg     local relief model blended over the hillshade, Web Mercator

Data is embedded as a script rather than fetched, so the page also works when
opened straight from disk.
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import numpy as np
from osgeo import gdal, osr

sys.path.insert(0, str(Path(__file__).resolve().parent))
from render_maps import RELIEF, read_config  # noqa: E402

gdal.UseExceptions()

LAYERS = ["aoi", "available", "no_go", "consult", "scheduled_nearby", "listed_nearby"]
PIXEL_M = 1.5  # web image resolution in Web Mercator metres


def geojson(gpkg, layer, tmp, precision=6, simplify_m=0):
    path = Path(tmp) / f"{layer}.geojson"
    gdal.VectorTranslate(str(path), str(gpkg), layers=[layer], format="GeoJSON",
                         dstSRS="EPSG:4326", simplifyTolerance=simplify_m,
                         layerCreationOptions=["RFC7946=YES", f"COORDINATE_PRECISION={precision}"])
    return json.loads(path.read_text())


def summary(db):
    result = subprocess.run(["duckdb", "-readonly", "-json", str(db), "-c", "FROM summary"],
                            check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def blend_relief(terrain, tmp):
    """Colour the LRM and blend it over the hillshade, as in relief.jpg."""
    hs_ds = gdal.Open(str(terrain / "hillshade.tif"))
    hillshade = hs_ds.ReadAsArray().astype("float32") / 255
    lrm = gdal.Open(str(terrain / "lrm.tif")).ReadAsArray()
    colour = RELIEF(np.clip((lrm + 0.5) / 1.0, 0, 1))[..., :3]
    rgb = 0.75 * colour + 0.25 * hillshade[..., None]
    path = Path(tmp) / "relief_27700.tif"
    out = gdal.GetDriverByName("GTiff").Create(str(path), hs_ds.RasterXSize, hs_ds.RasterYSize,
                                               3, gdal.GDT_Byte)
    out.SetGeoTransform(hs_ds.GetGeoTransform())
    out.SetProjection(hs_ds.GetProjection())
    for band in range(3):
        out.GetRasterBand(band + 1).WriteArray((rgb[..., band] * 255).astype("uint8"))
    out = None
    return path


def to_web_jpeg(src, dest, tmp, pixel_m=PIXEL_M, fill=None):
    """Warp to Web Mercator, save as JPEG, return Leaflet [[south, west], [north, east]].

    fill sets the value for pixels with no source data, such as the corners
    exposed by reprojection.
    """
    warped = Path(tmp) / f"{dest.stem}_3857.tif"
    ds = gdal.Warp(str(warped), str(src), dstSRS="EPSG:3857", xRes=pixel_m, yRes=pixel_m,
                   resampleAlg="bilinear",
                   warpOptions=[] if fill is None else [f"INIT_DEST={fill}"])
    gt = ds.GetGeoTransform()
    xmin, ymax = gt[0], gt[3]
    xmax, ymin = xmin + gt[1] * ds.RasterXSize, ymax + gt[5] * ds.RasterYSize
    gdal.Translate(str(dest), ds, format="JPEG", creationOptions=["QUALITY=85"])
    ds = None
    Path(str(dest) + ".aux.xml").unlink(missing_ok=True)

    mercator, wgs84 = osr.SpatialReference(), osr.SpatialReference()
    mercator.ImportFromEPSG(3857)
    wgs84.ImportFromEPSG(4326)
    wgs84.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
    transform = osr.CoordinateTransformation(mercator, wgs84)
    west, south, _ = transform.TransformPoint(xmin, ymin)
    east, north, _ = transform.TransformPoint(xmax, ymax)
    return [[round(south, 6), round(west, 6)], [round(north, 6), round(east, 6)]]


def main():
    out, dest = Path(sys.argv[1]), Path(sys.argv[2])
    dest.mkdir(parents=True, exist_ok=True)
    name = out.name
    terrain = out / "terrain"
    config = read_config(Path(__file__).resolve().parent.parent / "config.env")

    with tempfile.TemporaryDirectory() as tmp:
        data = {
            "name": name.replace("_", " ").capitalize(),
            "layers": {layer: geojson(out / f"{name}.gpkg", layer, tmp) for layer in LAYERS},
            "summary": summary(out / "assessment.duckdb"),
            "params": {key.lower(): int(config[key]) for key in
                       ["GPS_MARGIN_M", "CONTEXT_RADIUS_M", "LRM_WINDOW_M"]},
            "images": {
                "hillshade": to_web_jpeg(terrain / "hillshade.tif", dest / "hillshade.jpg", tmp),
                "relief": to_web_jpeg(blend_relief(terrain, tmp), dest / "relief.jpg", tmp),
            },
        }

    (dest / "data.js").write_text("window.MAP_DATA = " + json.dumps(data, separators=(",", ":")) + ";\n")
    print(f"Wrote {dest}/data.js, hillshade.jpg, relief.jpg")


if __name__ == "__main__":
    main()

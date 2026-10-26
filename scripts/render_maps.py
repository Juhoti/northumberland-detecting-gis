"""Render static maps for one assessed area of interest.

Usage: python3 scripts/render_maps.py output/<name>

Reads output/<name>/<name>.gpkg and output/<name>/terrain/, writes
output/<name>/constraints.png and output/<name>/relief.jpg.
"""

import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.patheffects as pe
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.colors import LinearSegmentedColormap
from matplotlib.lines import Line2D
from matplotlib.patches import Patch, PathPatch, Rectangle
from matplotlib.path import Path as MplPath
from osgeo import gdal, ogr

gdal.UseExceptions()
ogr.UseExceptions()

NO_GO = "#d03b3b"
CONSULT = "#fab219"
AVAILABLE = "#0ca30c"
ACCESS = "#2a78d6"
LISTED = "#6250d6"
INK = "#0b0b0b"
MUTED = "#52514e"

# Diverging blue (hollows) to red (rises) through a neutral grey midpoint.
RELIEF = LinearSegmentedColormap.from_list(
    "relief", ["#104281", "#3987e5", "#f0efec", "#e34948", "#8f1d1d"]
)

ATTRIBUTION = (
    "LiDAR: © Environment Agency copyright and/or database right 2022. "
    "Designations: © Historic England 2026; © Natural England 2026. "
    "Contains Ordnance Survey data © Crown copyright and database right 2026. "
    "Open Government Licence v3.0."
)


def read_raster(path):
    ds = gdal.Open(str(path))
    band = ds.GetRasterBand(1)
    data = band.ReadAsArray().astype("float32")
    nodata = band.GetNoDataValue()
    if nodata is not None:
        data = np.ma.masked_equal(data, nodata)
    gt = ds.GetGeoTransform()
    extent = (
        gt[0],
        gt[0] + gt[1] * ds.RasterXSize,
        gt[3] + gt[5] * ds.RasterYSize,
        gt[3],
    )
    return data, extent


def read_layer(gpkg, name):
    """Return [(attributes, geometry)] for every feature in a layer."""
    ds = ogr.Open(str(gpkg))
    layer = ds.GetLayerByName(name)
    features = []
    for feature in layer:
        geom = feature.GetGeometryRef()
        if geom is not None and not geom.IsEmpty():
            features.append((feature.items(), geom.Clone()))
    return features


def signed_area(points):
    xs, ys = points[:, 0], points[:, 1]
    return 0.5 * np.sum(xs * np.roll(ys, -1) - np.roll(xs, -1) * ys)


def polygon_path(geom):
    """Matplotlib path for a (multi)polygon; holes are wound opposite to shells."""
    vertices, codes = [], []
    geom = ogr.ForceToMultiPolygon(geom)
    for i in range(geom.GetGeometryCount()):
        polygon = geom.GetGeometryRef(i)
        for j in range(polygon.GetGeometryCount()):
            ring = np.array(polygon.GetGeometryRef(j).GetPoints())[:, :2]
            clockwise = signed_area(ring) < 0
            if (j == 0) == clockwise:
                ring = ring[::-1]
            vertices.extend(ring)
            codes.extend([MplPath.MOVETO] + [MplPath.LINETO] * (len(ring) - 2) + [MplPath.CLOSEPOLY])
    return MplPath(vertices, codes)


def draw_polygons(ax, features, **style):
    for _, geom in features:
        ax.add_patch(PathPatch(polygon_path(geom), **style))


def wash_outside(ax, extent, geom, alpha, zorder):
    """Wash out the map outside a (multi)polygon, keeping the focus inside it."""
    # The frame runs clockwise, opposite to polygon_path's shells, so under the
    # nonzero fill rule the polygon becomes a hole in it.
    frame = MplPath([(extent[0], extent[2]), (extent[0], extent[3]), (extent[1], extent[3]),
                     (extent[1], extent[2]), (extent[0], extent[2])], closed=True)
    path = MplPath.make_compound_path(frame, polygon_path(geom))
    ax.add_patch(PathPatch(path, facecolor="white", alpha=alpha, edgecolor="none",
                           zorder=zorder))


def halo(width=3):
    return [pe.withStroke(linewidth=width, foreground="white")]


def label_monuments(ax, features, extent):
    for attrs, geom in features:
        point = geom.PointOnSurface()
        x, y = point.GetX(), point.GetY()
        if extent[0] < x < extent[1] and extent[2] < y < extent[3]:
            ax.text(x, y, attrs["ref"], fontsize=7.5, color=INK, ha="center", va="center",
                    weight="bold", path_effects=halo(), zorder=9)


def scale_bar(ax, extent, length=500, anchor=(0.05, 0.04)):
    x0 = extent[0] + anchor[0] * (extent[1] - extent[0])
    y0 = extent[2] + anchor[1] * (extent[3] - extent[2])
    height = 0.012 * (extent[3] - extent[2])
    half = length / 2
    unit, metres = ("km", 1000) if length >= 1000 else ("m", 1)
    for i, colour in enumerate([INK, "white", INK, "white"]):
        ax.add_patch(Rectangle((x0 + i * half / 2, y0), half / 2, height, facecolor=colour,
                               edgecolor=INK, linewidth=0.8, zorder=10))
    for offset, text in [(0, "0"), (half, f"{half / metres:g}"),
                         (length, f"{length / metres:g} {unit}")]:
        ax.text(x0 + offset, y0 + height * 1.6, text, fontsize=7.5, ha="center", va="bottom",
                color=INK, path_effects=halo(), zorder=10)


def north_arrow(ax):
    ax.annotate("N", xy=(0.95, 0.95), xytext=(0.95, 0.87), xycoords="axes fraction",
                ha="center", va="center", fontsize=11, weight="bold", color=INK,
                arrowprops=dict(arrowstyle="-|>", color=INK, linewidth=1.5),
                path_effects=halo(), zorder=10)


def grid(ax, extent, step=500):
    xs = np.arange(np.ceil(extent[0] / step) * step, extent[1], step)
    ys = np.arange(np.ceil(extent[2] / step) * step, extent[3], step)
    ax.set_xticks(xs)
    ax.set_yticks(ys)
    ax.set_xticklabels([f"{x:,.0f}" for x in xs], fontsize=7, color=MUTED)
    ax.set_yticklabels([f"{y:,.0f}" for y in ys], fontsize=7, color=MUTED, rotation=90, va="center")
    ax.grid(True, color="white", linewidth=0.5, alpha=0.6)
    ax.tick_params(length=3, color=MUTED)
    for spine in ax.spines.values():
        spine.set_edgecolor(MUTED)
        spine.set_linewidth(0.8)


def new_map(extent, title, subtitle, attribution=ATTRIBUTION):
    map_w = 7.5
    map_h = map_w * (extent[3] - extent[2]) / (extent[1] - extent[0])
    left, right, top, bottom = 0.75, 3.3, 1.15, 0.85
    fig_w, fig_h = left + map_w + right, bottom + map_h + top
    fig = plt.figure(figsize=(fig_w, fig_h), facecolor="white")
    ax = fig.add_axes([left / fig_w, bottom / fig_h, map_w / fig_w, map_h / fig_h])
    ax.set_xlim(extent[0], extent[1])
    ax.set_ylim(extent[2], extent[3])
    ax.set_aspect("equal")
    fig.text(left / fig_w, 1 - 0.3 / fig_h, title, fontsize=15, weight="bold", color=INK, va="top")
    fig.text(left / fig_w, 1 - 0.68 / fig_h, subtitle, fontsize=9.5, color=MUTED, va="top",
             linespacing=1.4)
    fig.text(left / fig_w, 0.2 / fig_h, attribution, fontsize=6, color=MUTED, wrap=True)
    return fig, ax


def add_legend(fig, ax, handles, title):
    legend = fig.legend(handles=handles, title=title, loc="upper left",
                        bbox_to_anchor=(ax.get_position().x1 + 0.015, ax.get_position().y1),
                        frameon=False, fontsize=8.5, title_fontsize=9.5, alignment="left",
                        handlelength=2.2, handleheight=1.4, labelspacing=0.9)
    legend.get_title().set_weight("bold")


def summary_line(gpkg):
    aoi = read_layer(gpkg, "aoi")[0][0]["area_ha"]
    available = read_layer(gpkg, "available")[0][0]["area_ha"]
    return aoi, available


def render_constraints(out, gpkg, hillshade, extent, name, config):
    aoi_ha, available_ha = summary_line(gpkg)
    no_go = read_layer(gpkg, "no_go")
    consult = read_layer(gpkg, "consult")
    nearby = read_layer(gpkg, "scheduled_nearby")
    listed = read_layer(gpkg, "listed_nearby")
    count = len({a["ref"] for a, _ in no_go})

    fig, ax = new_map(
        extent,
        "Detecting constraints",
        f"{name}: {aoi_ha:,.1f} ha. {available_ha:,.1f} ha ({100 * available_ha / aoi_ha:.1f}%) "
        f"lies outside scheduled monuments and the {config['GPS_MARGIN_M']} m GPS margin.\n"
        f"{count} scheduled monument{'s' if count != 1 else ''} intersect"
        f"{'s' if count == 1 else ''} the area.",
    )
    ax.imshow(hillshade, cmap="gray", extent=extent, vmin=40, vmax=255, interpolation="bilinear")
    aoi = read_layer(gpkg, "aoi")
    wash_outside(ax, extent, aoi[0][1], alpha=0.45, zorder=1)

    draw_polygons(ax, read_layer(gpkg, "available"), facecolor=AVAILABLE, alpha=0.07,
                  edgecolor="none", zorder=2)
    access = [f for f in consult if f[0]["class"] == "info"]
    caution = [f for f in consult if f[0]["class"] == "consult"]
    draw_polygons(ax, access, facecolor="none", edgecolor=ACCESS, linewidth=1.2,
                  linestyle=(0, (2, 2)), hatch=".", zorder=3)
    draw_polygons(ax, caution, facecolor=CONSULT, alpha=0.35, edgecolor=CONSULT,
                  hatch="\\\\", linewidth=1, zorder=4)

    outside = [f for f in nearby if not f[0]["overlaps_aoi"]]
    draw_polygons(ax, outside, facecolor="none", edgecolor=NO_GO, linewidth=1.2,
                  linestyle=(0, (4, 2)), zorder=5)
    margin = [f for f in no_go if f[0]["kind"] == "GPS margin"]
    scheduled = [f for f in no_go if f[0]["kind"] == "scheduled area"]
    draw_polygons(ax, margin, facecolor=NO_GO, alpha=0.30, edgecolor="none", zorder=6)
    draw_polygons(ax, scheduled, facecolor=(0.82, 0.23, 0.23, 0.55), edgecolor=NO_GO,
                  hatch="////", linewidth=1.2, zorder=7)
    draw_polygons(ax, aoi, facecolor="none", edgecolor=INK, linewidth=2, zorder=8)

    for _, geom in listed:
        for i in range(geom.GetGeometryCount()):
            p = geom.GetGeometryRef(i)
            ax.plot(p.GetX(), p.GetY(), marker="^", markersize=8, color=LISTED,
                    markeredgecolor="white", zorder=9)

    label_monuments(ax, nearby, extent)
    grid(ax, extent)
    scale_bar(ax, extent)
    north_arrow(ax)

    def present(features, label):
        return label if features else label + " (none)"

    handles = [
        Line2D([], [], color=INK, linewidth=2, label="Area of interest"),
        Patch(facecolor=(0.82, 0.23, 0.23, 0.55), edgecolor=NO_GO, hatch="////",
              label=present(scheduled, "No-go: scheduled monument\n(AMAA Act 1979, s.42)")),
        Patch(facecolor=NO_GO, alpha=0.30, edgecolor="none",
              label=present(margin, "No-go: GPS margin")),
        Line2D([], [], color=NO_GO, linewidth=1.2, linestyle=(0, (4, 2)),
               label=present(outside, f"Scheduled monument within\n{config['CONTEXT_RADIUS_M']} m")),
        Patch(facecolor=CONSULT, alpha=0.35, edgecolor=CONSULT, hatch="\\\\",
              label=present(caution, "Consult first: SSSI, registered\npark, battlefield or WHS")),
        Patch(facecolor="none", edgecolor=ACCESS, hatch=".", linestyle=(0, (2, 2)),
              label=present(access, "CRoW open access land\n(information)")),
        Patch(facecolor=AVAILABLE, alpha=0.18, edgecolor="none", label="Available for detecting"),
        Line2D([], [], marker="^", color=LISTED, linestyle="none", markersize=8,
               markeredgecolor="white",
               label=present(listed, f"Listed building within\n{config['CONTEXT_RADIUS_M']} m")),
    ]
    add_legend(fig, ax, handles, "Legend")
    fig.text(ax.get_position().x1 + 0.015, 0.12,
             "Labels are National Heritage List\nentry numbers. Grid: British National\n"
             "Grid (EPSG:27700), metres.\n\nNot legal advice. Check the current\n"
             "list entry before detecting.",
             fontsize=7.5, color=MUTED, va="bottom")
    fig.savefig(out / "constraints.png", dpi=170)
    plt.close(fig)


def render_relief(out, gpkg, hillshade, lrm, extent, config):
    window = int(config["LRM_WINDOW_M"]) // 2 * 2 + 1
    fig, ax = new_map(
        extent,
        "Local relief model",
        f"Ground height relative to its {config['LRM_WINDOW_M']} m neighbourhood: "
        "banks and rises in red, ditches and hollows in blue.\n"
        "Scheduled monuments dashed, area of interest solid.",
    )
    ax.imshow(hillshade, cmap="gray", extent=extent, vmin=0, vmax=255, interpolation="bilinear")
    image = ax.imshow(lrm, cmap=RELIEF, extent=extent, vmin=-0.5, vmax=0.5, alpha=0.75,
                      interpolation="bilinear")
    draw_polygons(ax, read_layer(gpkg, "scheduled_nearby"), facecolor="none", edgecolor=INK,
                  linewidth=1.2, linestyle=(0, (4, 2)), zorder=5)
    draw_polygons(ax, read_layer(gpkg, "aoi"), facecolor="none", edgecolor=INK, linewidth=2,
                  zorder=6)
    label_monuments(ax, read_layer(gpkg, "scheduled_nearby"), extent)
    grid(ax, extent)
    scale_bar(ax, extent)
    north_arrow(ax)

    pos = ax.get_position()
    cax = fig.add_axes([pos.x1 + 0.03, pos.y1 - 0.35, 0.025, 0.33])
    bar = fig.colorbar(image, cax=cax, extend="both")
    bar.set_label("Relief (m)", fontsize=8.5, color=INK)
    bar.ax.tick_params(labelsize=7.5, colors=MUTED)
    bar.outline.set_edgecolor(MUTED)
    fig.text(pos.x1 + 0.015, 0.12,
             f"Method: 1 m EA LiDAR DTM minus a\n{window} x {window} m focal mean (simplified\n"
             "local relief model), over a\nmultidirectional hillshade.\n\n"
             "Colour stretch clipped at ±0.5 m.",
             fontsize=7.5, color=MUTED, va="bottom")
    # Relief texture compresses poorly as PNG; JPEG keeps the file small.
    fig.savefig(out / "relief.jpg", dpi=170, pil_kwargs={"quality": 90})
    plt.close(fig)


def read_config(path):
    config = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            config[key] = value
    return config


def main():
    out = Path(sys.argv[1])
    config = read_config(Path(__file__).resolve().parent.parent / "config.env")
    name = out.name
    gpkg = out / f"{name}.gpkg"
    hillshade, extent = read_raster(out / "terrain" / "hillshade.tif")
    lrm, _ = read_raster(out / "terrain" / "lrm.tif")
    title = name.replace("_", " ").capitalize()
    render_constraints(out, gpkg, hillshade, extent, title, config)
    render_relief(out, gpkg, hillshade, lrm, extent, config)
    print(f"Wrote {out / 'constraints.png'} and {out / 'relief.jpg'}")


if __name__ == "__main__":
    main()

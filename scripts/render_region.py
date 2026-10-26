"""Render the regional overview map.

Usage: python3 scripts/render_region.py output/region

Reads output/region/region.gpkg, output/region/hillshade.tif, region/places.csv
and the example boundaries in aoi/examples/, and writes output/region/overview.png.
Only committed example boundaries are drawn, so a private permission can never
appear on the overview.
"""

import csv
import json
import re
import subprocess
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.lines import Line2D
from matplotlib.patches import Patch, PathPatch
from matplotlib.path import Path as MplPath
from osgeo import ogr

sys.path.insert(0, str(Path(__file__).resolve().parent))
from render_maps import (  # noqa: E402
    ACCESS, CONSULT, INK, MUTED, NO_GO, add_legend, draw_polygons, grid, halo, new_map,
    north_arrow, read_config, read_layer, read_raster, scale_bar, wash_outside,
)

ROOT = Path(__file__).resolve().parent.parent
RIVER = "#6f9bcb"
OUTSIDE = "#e9e8e4"

ATTRIBUTION = (
    "LiDAR and catchments: © Environment Agency copyright and/or database right 2022–2026. "
    "Designations: © Historic England 2026; © Natural England 2026. "
    "Contains Ordnance Survey data © Crown copyright and database right 2026. "
    "Open Government Licence v3.0. Place positions © OpenStreetMap contributors (ODbL)."
)


def whole_region(db):
    result = subprocess.run(
        ["duckdb", "-readonly", "-json", str(db), "-c",
         "FROM summary WHERE area = 'Whole region'"],
        check=True, capture_output=True, text=True)
    return json.loads(result.stdout)[0]


def draw_lines(ax, features, **style):
    for _, geom in features:
        geom = ogr.ForceToMultiLineString(geom)
        for i in range(geom.GetGeometryCount()):
            points = np.array(geom.GetGeometryRef(i).GetPoints())
            ax.plot(points[:, 0], points[:, 1], solid_capstyle="round", **style)


def short_battle_name(name):
    """'The Site of The Battle of Halidon Hill 1333' -> 'Halidon Hill 1333'."""
    return re.sub(r"^(The Site of )?The Battle of |^Battle of ", "", name, flags=re.IGNORECASE)


def wrap(text, width=12):
    """Split a long label over two lines at the space nearest its middle."""
    if len(text) <= width or " " not in text:
        return text
    spaces = [i for i, c in enumerate(text) if c == " "]
    cut = min(spaces, key=lambda i: abs(i - len(text) / 2))
    return text[:cut] + "\n" + text[cut + 1:]


# Label offset (metres) and alignment for each placement in places.csv.
PLACEMENT = {
    "right": (900, 0, "left", "center"),
    "left": (-900, 0, "right", "center"),
    "above": (0, 900, "center", "bottom"),
    "below": (0, -900, "center", "top"),
}


def label_places(ax):
    """Area names, settlements and landmarks from region/places.csv."""
    with open(ROOT / "region" / "places.csv", newline="") as f:
        places = list(csv.DictReader(f))
    for place in places:
        x, y = float(place["easting"]), float(place["northing"])
        kind = place["kind"]
        if kind == "area":
            ax.text(x, y, wrap(place["name"].upper()), fontsize=9.5, color=INK, weight="bold",
                    ha="center", va="center", linespacing=1.1, path_effects=halo(3), zorder=11)
            continue
        if kind == "water":
            ax.text(x, y, place["name"], fontsize=7.5, color="#1c5cab", style="italic",
                    ha="center", va="center", path_effects=halo(2.5), zorder=12)
            continue
        marker, size, weight = {
            "town": ("s", 5, "bold"),
            "village": ("o", 3.5, "normal"),
            "peak": ("^", 6, "normal"),
        }[kind]
        ax.plot(x, y, marker=marker, markersize=size, color=INK, markeredgecolor="white",
                markeredgewidth=0.6, zorder=12)
        dx, dy, ha, va = PLACEMENT[place["label"] or "right"]
        ax.text(x + dx, y + dy, place["name"], fontsize=7.5, color=INK, weight=weight,
                ha=ha, va=va, path_effects=halo(2.5), zorder=12)


def render_overview(out, config):
    gpkg = out / "region.gpkg"
    totals = whole_region(out / "region.duckdb")
    hillshade, extent = read_raster(out / "hillshade.tif")
    areas = read_layer(gpkg, "areas")
    consult = read_layer(gpkg, "consult")
    battlefields = [f for f in consult
                    if f[0]["designation"] == "Registered battlefield" and f[0]["in_region"]]

    fig, ax = new_map(
        extent,
        "Border country and Coquetdale",
        f"Statutory designations across {totals['area_km2']:,.0f} km² of north Northumberland: "
        f"{totals['scheduled_monuments']} scheduled monuments, "
        f"{totals['listed_buildings']:,} listed buildings,\n{totals['sssis']} SSSIs and "
        f"{len(battlefields)} registered battlefields. Scheduled monuments cover "
        f"{totals['scheduled_pct']:.2f}% of the land and open access land "
        f"{totals['access_pct']:.0f}%.",
        attribution=ATTRIBUTION,
    )

    # Scotland and the sea have no EA LiDAR; show them as a flat neutral.
    ax.add_patch(PathPatch(MplPath([(extent[0], extent[2]), (extent[1], extent[2]),
                                    (extent[1], extent[3]), (extent[0], extent[3])]),
                           facecolor=OUTSIDE, edgecolor="none", zorder=0))
    ax.imshow(hillshade, cmap="gray", extent=extent, vmin=60, vmax=255,
              interpolation="bilinear", zorder=0.5)

    draw_polygons(ax, read_layer(gpkg, "open_access"), facecolor=ACCESS, alpha=0.13,
                  edgecolor="none", zorder=1)
    draw_polygons(ax, read_layer(gpkg, "open_access"), facecolor="none", edgecolor=ACCESS,
                  linewidth=0.4, alpha=0.6, zorder=1)
    draw_lines(ax, read_layer(gpkg, "rivers"), color=RIVER, linewidth=0.6, zorder=1.5)
    draw_polygons(ax, consult, facecolor=CONSULT, alpha=0.35, edgecolor=CONSULT,
                  hatch="\\\\\\\\", linewidth=0.6, zorder=2)
    # Edges keep the smallest monuments visible at this scale.
    draw_polygons(ax, read_layer(gpkg, "scheduled_monuments"), facecolor=NO_GO,
                  edgecolor=NO_GO, linewidth=0.7, zorder=3)

    # Wash out everything beyond the region boundary.
    region = read_layer(gpkg, "region")
    wash_outside(ax, extent, region[0][1], alpha=0.55, zorder=4)

    draw_polygons(ax, areas, facecolor="none", edgecolor=INK, linewidth=0.9,
                  linestyle=(0, (5, 3)), zorder=5)
    draw_polygons(ax, region, facecolor="none", edgecolor=INK, linewidth=1.8, zorder=6)

    examples = []
    for path in sorted((ROOT / "aoi" / "examples").glob("*.geojson")):
        examples += read_layer(path, path.stem)
    draw_polygons(ax, examples, facecolor="white", alpha=0.7, edgecolor="none", zorder=7)
    draw_polygons(ax, examples, facecolor="none", edgecolor=INK, linewidth=1.2, zorder=7)
    for _, geom in examples:
        envelope = geom.GetEnvelope()
        ax.text(envelope[1] + 700, (envelope[2] + envelope[3]) / 2, "Demo area",
                fontsize=7.5, color=INK, style="italic", va="center", path_effects=halo(2.5),
                zorder=12)

    # Battlefield names sit just above each registered area.
    for attrs, geom in battlefields:
        xmin, xmax, _, ymax = geom.GetEnvelope()
        ax.text((xmin + xmax) / 2, ymax + 500, short_battle_name(attrs["name"]), fontsize=7,
                color="#7a5200", weight="bold", ha="center", va="bottom",
                path_effects=halo(2.5), zorder=11)

    ax.text(366000, 640000, "SCOTLAND", fontsize=10, color=MUTED, weight="bold",
            ha="center", va="center", zorder=11)
    ax.text(418000, 652000, "North Sea", fontsize=9, color=MUTED, style="italic",
            ha="center", va="center", zorder=11)
    label_places(ax)

    grid(ax, extent, step=10000)
    scale_bar(ax, extent, length=10000, anchor=(0.72, 0.04))
    north_arrow(ax)

    handles = [
        Line2D([], [], color=INK, linewidth=1.8, label="Region boundary"),
        Line2D([], [], color=INK, linewidth=0.9, linestyle=(0, (5, 3)), label="Area boundary"),
        Patch(facecolor=NO_GO, edgecolor=NO_GO, label="No-go: scheduled monument\n(AMAA Act 1979, s.42)"),
        Patch(facecolor=CONSULT, alpha=0.35, edgecolor=CONSULT, hatch="\\\\\\\\",
              label="Consult first: SSSI, registered\npark or battlefield"),
        Patch(facecolor=ACCESS, alpha=0.18, edgecolor=ACCESS, linewidth=0.4,
              label="CRoW open access land\n(information)"),
        Line2D([], [], color=RIVER, linewidth=1.2, label="River"),
        Patch(facecolor="white", edgecolor=INK, linewidth=1.2,
              label="Demo area (example\nassessment)"),
    ]
    add_legend(fig, ax, handles, "Legend")
    fig.text(ax.get_position().x1 + 0.015, 0.12,
             "Region: Environment Agency river\ncatchments of the Tweed and Till,\n"
             "Coquet, Rede and upper North Tyne.\nRecords beyond it are washed out.\n\n"
             "Scotland is not covered. Its\ndesignations are held by Historic\n"
             "Environment Scotland and NatureScot,\nand Scots law on finds differs.\n\n"
             f"Terrain: {config['REGION_RELIEF_M']} m hillshade, coarse by\n"
             "design. 1 m terrain is produced only\nfor an assessed area.\n\n"
             "Grid: British National Grid\n(EPSG:27700), metres.",
             fontsize=7.5, color=MUTED, va="bottom")
    fig.savefig(out / "overview.png", dpi=170)
    plt.close(fig)


def main():
    out = Path(sys.argv[1])
    config = read_config(ROOT / "config.env")
    render_overview(out, config)
    print(f"Wrote {out / 'overview.png'}")


if __name__ == "__main__":
    main()

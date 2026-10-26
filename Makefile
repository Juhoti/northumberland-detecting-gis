# Permission-first constraint assessment for metal detecting.
#
#   make              assess the AOI set in config.env (fetch data if missing)
#   make AOI=path     assess another boundary file
#   make web          refresh the web map in docs/map from the current AOI
#   make region       regional overview of designations in output/region
#   make region-web   refresh the regional web map in docs/region
#   make example      refresh the committed example output in docs/example
#   make refresh      re-download designations and catchments
#   make clean        remove output for the current AOI

include config.env

NAME := $(basename $(notdir $(AOI)))
OUT  := output/$(NAME)

REGION := output/region

.PHONY: all assess terrain maps report web region region-web example refresh clean

all: report

data/designations.gpkg:
	scripts/fetch_designations.sh

data/catchments.gpkg: region/catchments.csv
	scripts/fetch_region.sh

$(OUT)/$(NAME).gpkg: $(AOI) data/designations.gpkg sql/assess_aoi.sql sql/designations.sql \
                     scripts/assess_aoi.sh config.env
	scripts/assess_aoi.sh $(AOI)

$(OUT)/terrain/lrm.tif: $(OUT)/$(NAME).gpkg scripts/build_terrain.sh scripts/fetch_dtm.sh
	scripts/build_terrain.sh $(AOI)

$(OUT)/constraints.png: $(OUT)/$(NAME).gpkg $(OUT)/terrain/lrm.tif scripts/render_maps.py
	python3 scripts/render_maps.py $(OUT)

$(OUT)/report.md: $(OUT)/constraints.png scripts/write_report.sh
	scripts/write_report.sh $(AOI)

assess: $(OUT)/$(NAME).gpkg
terrain: $(OUT)/terrain/lrm.tif
maps: $(OUT)/constraints.png
report: $(OUT)/report.md

web: report
	python3 scripts/export_web.py $(OUT) docs/map

$(REGION)/region.gpkg: data/catchments.gpkg data/designations.gpkg sql/assess_region.sql \
                       sql/designations.sql scripts/assess_region.sh config.env
	scripts/assess_region.sh

$(REGION)/overview.png: $(REGION)/region.gpkg region/places.csv scripts/render_region.py
	python3 scripts/render_region.py $(REGION)

$(REGION)/report.md: $(REGION)/overview.png scripts/write_region_report.sh
	scripts/write_region_report.sh

region: $(REGION)/report.md

region-web: region
	python3 scripts/export_region_web.py $(REGION) docs/region

example: report region
	mkdir -p docs/example
	cp $(OUT)/report.md $(OUT)/constraints.png $(OUT)/relief.jpg docs/example/
	cp $(REGION)/overview.png docs/example/
	cp $(REGION)/report.md docs/example/region_report.md

refresh:
	scripts/fetch_designations.sh
	scripts/fetch_region.sh

clean:
	rm -rf $(OUT)

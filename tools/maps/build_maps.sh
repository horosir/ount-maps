#!/usr/bin/env bash
# #167: بيبني خرائط الدول (PMTiles) من Protomaps + طبقة تفاصيل من OSM، ويقسمها أجزاء < 1.9 ج.ب، ويكتب maps_manifest.json
# المصادر: Protomaps daily build (بيانات OpenStreetMap © مساهمو OpenStreetMap — ODbL) و Geofabrik extracts.
# الاستخدام: build_maps.sh <out_dir> <repo owner/name> [countries...]   (الافتراضى: egypt)
set -euo pipefail
OUT="${1:?out dir}"; REPO="${2:?owner/repo}"; shift 2 || true
COUNTRIES=("${@:-egypt}")
FAKE="${FAKE:-0}"                       # FAKE=1: اختبار بدون شبكة (ملفات وهمية)
MAXZ="${MAXZ:-15}"
mkdir -p "$OUT"; cd "$OUT"
PARTMAX="${PARTMAX:-$((1900*1024*1024))}"

bbox_of()   { case "$1" in egypt) echo "24.6,21.6,37.0,31.9";; *) echo "";; esac; }            # min_lon,min_lat,max_lon,max_lat
geofab_of() { case "$1" in egypt) echo "africa/egypt";; *) echo "";; esac; }
name_of()   { case "$1" in egypt) echo "مصر";; *) echo "$1";; esac; }

find_build() {   # آخر build متاح من Protomaps (بنجرّب آخر 12 يوم)
  for i in $(seq 0 12); do
    d=$(date -u -d "-$i day" +%Y%m%d)
    if curl -sfI "https://build.protomaps.com/${d}.pmtiles" >/dev/null; then echo "$d"; return 0; fi
  done; return 1
}

ENTRIES=()
add_entry() {   # id name ver file
  local id="$1" name="$2" ver="$3" f="$4" parts=() size i=0
  size=$(stat -c %s "$f")
  if [ "$size" -le "$PARTMAX" ]; then cp -f "$f" "${id}.pmtiles.000" 2>/dev/null || mv "$f" "${id}.pmtiles.000"
  else split -b "$PARTMAX" -d -a 3 "$f" "${id}.pmtiles."; fi
  local js="["
  for p in $(ls "${id}.pmtiles."[0-9][0-9][0-9] | sort); do
    local s h; s=$(stat -c %s "$p"); h=$(sha256sum "$p" | cut -d' ' -f1)
    [ "$i" -gt 0 ] && js+=","
    js+="{\"u\":\"https://github.com/${REPO}/releases/download/maps/${p}\",\"s\":${s},\"h\":\"${h}\"}"
    i=$((i+1))
  done
  js+="]"
  ENTRIES+=("{\"id\":\"${id}\",\"name\":\"${name}\",\"ver\":\"${ver}\",\"size\":${size},\"parts\":${js}}")
}

if [ "$FAKE" != "1" ]; then
  command -v pmtiles >/dev/null || { echo "pmtiles CLI مش موجود"; exit 1; }
  BUILD=$(find_build) || { echo "مفيش Protomaps build متاح"; exit 1; }
else BUILD=$(date -u +%Y%m%d); fi
echo "build=$BUILD"

for C in "${COUNTRIES[@]}"; do
  NAME=$(name_of "$C"); BB=$(bbox_of "$C"); GF=$(geofab_of "$C")
  [ -n "$BB" ] || { echo "دولة مش معرّفة: $C"; exit 1; }
  if [ "$FAKE" = "1" ]; then head -c 3500000 /dev/urandom > "base_$C.pmtiles"; head -c 1200000 /dev/urandom > "det_$C.pmtiles"
  else
    pmtiles extract "https://build.protomaps.com/${BUILD}.pmtiles" "base_$C.pmtiles" --bbox="$BB" --maxzoom="$MAXZ"
    # طبقة التفاصيل: كهوف/عيون/آبار/ترع/قناطر/خنادق/أنفاق... من OSM (بتتحدّث مع كل بناء)
    curl -fL "https://download.geofabrik.de/${GF}-latest.osm.pbf" -o "$C.osm.pbf"
    osmium tags-filter "$C.osm.pbf" \
      n/natural=cave_entrance,spring,hot_spring,peak,saddle,rock n/man_made=water_well,water_tap,water_tower,watermill,storage_tank n/amenity=drinking_water,fuel,shelter n/waterway=weir,lock_gate,waterfall,dam,stream_end \
      w/waterway=canal,drain,ditch,dam,weir w/man_made=tunnel,bridge,pipeline w/military=trench,bunker w/tunnel=yes,culvert w/bridge=yes w/natural=cave,wadi,sand,scrub,bare_rock,water,wetland w/landuse=farmland,orchard,quarry \
      -o "$C.details.osm.pbf" --overwrite
    osmium export "$C.details.osm.pbf" -f geojsonseq --add-unique-id=type_id -o "$C.details.geojsons" --overwrite
    tippecanoe -o "det_$C.pmtiles" -l details -Z6 -z"$MAXZ" --drop-densest-as-needed --extend-zooms-if-still-dropping --force --read-parallel "$C.details.geojsons"
    rm -f "$C.osm.pbf" "$C.details.osm.pbf" "$C.details.geojsons"
  fi
  add_entry "$C" "$NAME" "$BUILD" "base_$C.pmtiles"
  add_entry "${C}-details" "${NAME} — التفاصيل (آبار/عيون/كهوف/ترع/قناطر…)" "$BUILD" "det_$C.pmtiles"
  rm -f "base_$C.pmtiles" "det_$C.pmtiles"
done

{ printf '{"v":1,"built":"%s","attribution":"© OpenStreetMap contributors (ODbL) · Protomaps","maps":[' "$(date -u +%FT%TZ)"; (IFS=,; echo -n "${ENTRIES[*]}"); printf ']}\n'; } > maps_manifest.json
python3 -c "import json;m=json.load(open('maps_manifest.json'));print('manifest ok',[(e['id'],e['size'],len(e['parts'])) for e in m['maps']])"

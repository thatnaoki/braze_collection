#!/usr/bin/env bash
# Braze に Recommend1 / SimilarProduct カタログを作成し、CSV の中身を投入する。
#
#   export BRAZE_REST_ENDPOINT=https://todd.braze.com
#   export BRAZE_API_KEY=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   ./scripts/setup_braze_catalogs.sh
#
# API キーに必要な権限: catalogs.create / catalogs.add_items / catalogs.get
# docs: https://www.braze.com/docs/api/endpoints/catalogs
set -euo pipefail

: "${BRAZE_REST_ENDPOINT:?BRAZE_REST_ENDPOINT が未設定です (例: https://todd.braze.com)}"
: "${BRAZE_API_KEY:?BRAZE_API_KEY が未設定です}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$ROOT/connected_content/sample1_recommend_jsonfile"
ENDPOINT="${BRAZE_REST_ENDPOINT%/}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

api() { # api <METHOD> <PATH> [BODY_FILE]
  local method="$1" path="$2" file="${3-}"
  if [[ -n "$file" ]]; then
    curl -sS -w '\n%{http_code}' -X "$method" "$ENDPOINT$path" \
      -H "Authorization: Bearer $BRAZE_API_KEY" \
      -H "Content-Type: application/json" --data @"$file"
  else
    curl -sS -w '\n%{http_code}' -X "$method" "$ENDPOINT$path" \
      -H "Authorization: Bearer $BRAZE_API_KEY"
  fi
}

report() { # report <label> <curl output>
  local label="$1" out="$2"
  local code="${out##*$'\n'}" body="${out%$'\n'*}"
  printf '%-46s HTTP %s\n' "$label" "$code"
  [[ "$code" =~ ^2 ]] || { printf '  %s\n' "$body"; return 1; }
}

num_items() { # num_items <catalog_name> -> 件数、カタログ未作成なら空文字
  api GET /catalogs | sed '$d' | python3 -c '
import json,sys
name=sys.argv[1]
for c in json.load(sys.stdin).get("catalogs",[]):
    if c["name"]==name:
        print(c["num_items"]); break
' "$1"
}

create_catalog() { # create_catalog <name> <description> <fields-json>
  local name="$1" desc="$2" fields="$3" out code
  python3 -c '
import json,sys
print(json.dumps({"catalogs":[{"name":sys.argv[1],"description":sys.argv[2],
                               "fields":json.loads(sys.argv[3])}]}))' \
    "$name" "$desc" "$fields" > "$TMP/catalog.json"

  out=$(api POST /catalogs "$TMP/catalog.json")
  code="${out##*$'\n'}"
  if [[ "$code" == "409" ]] || grep -q 'already exists' <<<"$out"; then
    printf '%-46s SKIP (already exists)\n' "create catalog: $name"
  else
    report "create catalog: $name" "$out"
  fi

  # 作成直後は非同期の item 投入が取りこぼされることがあるので、
  # カタログが GET /catalogs に現れるまで待ってから次へ進む。
  local i
  for i in $(seq 1 15); do
    [[ -n "$(num_items "$name")" ]] && return 0
    python3 -c 'import time; time.sleep(2)'
  done
  echo "  警告: $name が GET /catalogs に現れませんでした" >&2
}

# CSV を 50 件ずつのチャンクに割って POST /catalogs/{name}/items に投入する。
# (Braze の上限は 1 リクエストあたり 50 items)
upload_items() { # upload_items <catalog_name> <csv-path> <numeric-cols> <bool-cols>
  local name="$1" csv="$2" nums="${3-}" bools="${4-}" n=0 f

  python3 - "$csv" "$nums" "$bools" "$TMP" <<'PY'
import csv, json, sys
path, nums, bools, tmp = sys.argv[1], set(filter(None, sys.argv[2].split(","))), set(filter(None, sys.argv[3].split(","))), sys.argv[4]
rows = []
with open(path, newline="", encoding="utf-8") as f:
    for row in csv.DictReader(f):
        item = {}
        for k, v in row.items():
            k, v = k.strip(), (v or "").strip()
            if k in nums:
                item[k] = float(v) if "." in v else int(v)
            elif k in bools:
                item[k] = v.lower() == "true"
            else:
                item[k] = v
        rows.append(item)
for i, start in enumerate(range(0, len(rows), 50)):
    with open(f"{tmp}/chunk_{i:03d}.json", "w") as f:
        json.dump({"items": rows[start:start+50]}, f)
print(f"{len(rows)} items -> {(len(rows)+49)//50} batch(es)")
PY

  for f in "$TMP"/chunk_*.json; do
    n=$((n+1))
    report "upload items: $name (batch $n)" "$(api POST "/catalogs/$name/items" "$f")"
  done
  rm -f "$TMP"/chunk_*.json

  # 非同期なので、実際に件数が反映されるまでポーリングして確認する。
  local expected i got
  expected=$(python3 -c 'import csv,sys;print(sum(1 for _ in csv.DictReader(open(sys.argv[1],newline="",encoding="utf-8"))))' "$csv")
  for i in $(seq 1 20); do
    got=$(num_items "$name")
    if [[ "$got" == "$expected" ]]; then
      printf '%-46s OK (%s items)\n' "verify: $name" "$got"
      return 0
    fi
    python3 -c 'import time; time.sleep(3)'
  done
  printf '%-46s 件数不一致 (期待 %s / 実際 %s)\n' "verify: $name" "$expected" "${got:-?}" >&2
  return 1
}

echo "== Braze endpoint: $ENDPOINT"
echo

create_catalog Recommend1 "Connected Content sample product catalog" '[
  {"name":"id","type":"string"},
  {"name":"product_title","type":"string"},
  {"name":"price","type":"number"},
  {"name":"currency","type":"string"},
  {"name":"category","type":"string"},
  {"name":"image_url","type":"string"},
  {"name":"product_url","type":"string"},
  {"name":"in_stock","type":"boolean"}
]'
upload_items Recommend1 "$DATA/catalog.csv" "price" "in_stock"
echo

create_catalog SimilarProduct "Similar product mapping for Connected Content sample" '[
  {"name":"id","type":"string"},
  {"name":"sku","type":"string"},
  {"name":"similar","type":"string"},
  {"name":"title","type":"string"}
]'
upload_items SimilarProduct "$DATA/catalog_similar_product.csv"

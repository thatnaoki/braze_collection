#!/usr/bin/env bash
# Braze に Recommend1 / SimilarProduct カタログを作成し、CSV の中身を投入する。
#
#   export BRAZE_REST_ENDPOINT=https://rest.sondheim.braze.com
#   export BRAZE_API_KEY=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   ./scripts/setup_braze_catalogs.sh
#
# API キーに必要な権限: catalogs.create / catalogs.add_items / catalogs.get
# docs: https://www.braze.com/docs/api/endpoints/catalogs
set -euo pipefail

: "${BRAZE_REST_ENDPOINT:?BRAZE_REST_ENDPOINT が未設定です (例: https://rest.sondheim.braze.com)}"
: "${BRAZE_API_KEY:?BRAZE_API_KEY が未設定です}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$ROOT/connected_content/sample1_recommend_jsonfile"
ENDPOINT="${BRAZE_REST_ENDPOINT%/}"

api() { # api <METHOD> <PATH> [BODY]
  local method="$1" path="$2" body="${3-}"
  if [[ -n "$body" ]]; then
    curl -sS -w '\n%{http_code}' -X "$method" "$ENDPOINT$path" \
      -H "Authorization: Bearer $BRAZE_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$body"
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

create_catalog() { # create_catalog <name> <description> <fields-json>
  local name="$1" desc="$2" fields="$3"
  local body out code
  body=$(python3 -c '
import json,sys
print(json.dumps({"catalogs":[{"name":sys.argv[1],"description":sys.argv[2],
                               "fields":json.loads(sys.argv[3])}]}))' "$name" "$desc" "$fields")
  out=$(api POST /catalogs "$body")
  code="${out##*$'\n'}"
  if [[ "$code" == "409" ]] || grep -q 'already exists' <<<"$out"; then
    printf '%-46s SKIP (already exists)\n' "create catalog: $name"
  else
    report "create catalog: $name" "$out"
  fi
}

# CSV を 50 件ずつのチャンクに割って POST /catalogs/{name}/items に投入する。
# (Braze の上限は 1 リクエストあたり 50 items)
upload_items() { # upload_items <catalog_name> <csv-path> <numeric-cols-csv> <bool-cols-csv>
  local name="$1" csv="$2" nums="${3-}" bools="${4-}"
  local chunks n=0
  chunks=$(python3 - "$csv" "$nums" "$bools" <<'PY'
import csv, json, sys
path, nums, bools = sys.argv[1], set(filter(None, sys.argv[2].split(","))), set(filter(None, sys.argv[3].split(",")))
rows = []
with open(path, newline="", encoding="utf-8") as f:
    for row in csv.DictReader(f):
        item = {}
        for k, v in row.items():
            k = k.strip()
            v = (v or "").strip()
            if k in nums:
                item[k] = float(v) if "." in v else int(v)
            elif k in bools:
                item[k] = v.lower() == "true"
            else:
                item[k] = v
        rows.append(item)
for i in range(0, len(rows), 50):
    print(json.dumps({"items": rows[i:i+50]}))
PY
)
  while IFS= read -r chunk; do
    n=$((n+1))
    report "upload items: $name (batch $n)" "$(api POST "/catalogs/$name/items" "$chunk")"
  done <<<"$chunks"
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
echo

echo "== 投入結果の確認"
report "list catalogs" "$(api GET /catalogs)" || true

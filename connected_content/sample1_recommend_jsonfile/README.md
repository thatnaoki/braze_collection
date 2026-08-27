# sample1_recommend_jsonfile

GitHub 上に置いた JSON を Connected Content で取得し、その ID で Braze の Catalog を引くサンプル。
API サーバーを立てずに Connected Content + Catalog + Liquid の組み合わせを試せる。

## 構成

| ファイル | 用途 |
| --- | --- |
| `recommended_items.json` | Connected Content で取得するレコメンド結果（ID 2件: 1908, 1909） |
| `recommended_items3.json` | 同上、3件版（1910, 1911, 1912） |
| `recommended_items2.json` | ネストしたレスポンス構造の例 |
| `item_info_product_1.json` | 単一アイテム情報の例 |
| `catalog.csv` | Braze カタログ `Recommend1` の元データ |
| `catalog_similar_product.csv` | Braze カタログ `SimilarProduct` の元データ |

## (1) Braze にカタログを作る

リポジトリルートで:

```bash
export BRAZE_REST_ENDPOINT=https://rest.sondheim.braze.com
export BRAZE_API_KEY=<catalogs.create / catalogs.add_items 権限を持つ REST API キー>
./scripts/setup_braze_catalogs.sh
```

`Recommend1` と `SimilarProduct` が作られ、CSV の中身が投入される。
ダッシュボードから手で入れる場合は **Data Settings > Catalogs** で CSV をアップロードし、
名前を `Recommend1` にすること（下の Liquid がこの名前を参照している）。

### Recommend1 のスキーマ

| field | type |
| --- | --- |
| id | string |
| product_title | string |
| price | number |
| currency | string |
| category | string |
| image_url | string |
| product_url | string |
| in_stock | boolean |

## (2) メッセージ内の Liquid

```liquid
{% connected_content
  https://raw.githubusercontent.com/thatnaoki/braze_collection/main/connected_content/sample1_recommend_jsonfile/recommended_items.json
  :content_type application/json
  :save result
%}

Hi, the recommended item is {{result}}

Hi, the recommended item is {{result.recommended_items[0]}}!!!!

{% catalog_items Recommend1 {{result.recommended_items[0]}} {{result.recommended_items[1]}} %}

{% for item in items %} {{ item.product_title }} {% endfor %}
```

### 追加フィールドまで使う例

```liquid
{% connected_content
  https://raw.githubusercontent.com/thatnaoki/braze_collection/main/connected_content/sample1_recommend_jsonfile/recommended_items3.json
  :content_type application/json
  :cache_max_age 300
  :save result
%}

{% catalog_items Recommend1 {{result.recommended_items[0]}} {{result.recommended_items[1]}} {{result.recommended_items[2]}} %}

{% for item in items %}
- {{ item.product_title }} / {{ item.price }} {{ item.currency }} / {{ item.category }}{% unless item.in_stock %} (在庫なし){% endunless %}
  {{ item.product_url }}
{% endfor %}
```

## メモ

- `{% catalog_items %}` の結果は必ず `items` という変数に入る（`:save` のような別名指定はできない）。
- Connected Content はメッセージ送信のたびに外部を叩くので、変化の少ないデータは `:cache_max_age`（5〜14400秒）を付ける。
- private リポジトリの raw URL は無認証だと 404 になる。private のまま使う場合は
  `:headers {"Authorization": "Bearer <PAT>"}` か、Braze の stored credentials（`:auth_credentials`）を使う。

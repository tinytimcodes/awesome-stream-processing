#!/bin/bash
set -e
set -o pipefail

# --- Configuration ---
SUPERSET_URL="${SUPERSET_URL:-http://localhost:8088}"
SUPERSET_USERNAME="${SUPERSET_USERNAME:-admin}"
SUPERSET_PASSWORD="${SUPERSET_PASSWORD:-admin}"
DB_NAME="RisingWave_Position_Risk"
SQLALCHEMY_URI="risingwave://root@risingwave:4566/dev"
DATASET_TABLE_NAME="position_overview"
DATASET_NAME="Position Overview"

# --- Helper Function ---
get_or_create_asset() {
   local asset_type="$1"; local asset_name="$2"; local filter_q="$3"; local create_payload="$4"
   echo "--- Managing ${asset_type^}: '$asset_name' ---" >&2
   local get_response; get_response=$(curl -s -G "$SUPERSET_URL/api/v1/$asset_type/" \
                                    -H "Authorization: Bearer $TOKEN" \
                                    --data-urlencode "$filter_q")
   local existing_id; existing_id=$(echo "$get_response" | jq -r '.result[0].id // empty')
   if [[ -n "$existing_id" ]]; then
     echo "$existing_id"
     return
   fi
   local create_response; create_response=$(curl -s -X POST "$SUPERSET_URL/api/v1/$asset_type/" \
                                        -H "Authorization: Bearer $TOKEN" \
                                        -H "X-CSRFToken: $CSRF_TOKEN" \
                                        -H "Content-Type: application/json" \
                                        -d "$create_payload")
   local new_id; new_id=$(echo "$create_response" | jq -r '.id // empty')
   [[ -z "$new_id" ]] && echo "Failed to create $asset_type '$asset_name': $create_response" >&2 && exit 1
   echo "$new_id"
}

# --- Auth ---
until curl -s "$SUPERSET_URL/api/v1/ping" &> /dev/null; do sleep 1; done
sleep 10
LOGIN_RESPONSE=$(curl -s -X POST "$SUPERSET_URL/api/v1/security/login" \
                     -H 'Content-Type: application/json' \
                     -d "{\"username\": \"$SUPERSET_USERNAME\", \"password\": \"$SUPERSET_PASSWORD\", \"provider\": \"db\"}")
TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.access_token // empty')
[[ -z "$TOKEN" ]] && echo "Login failed: $LOGIN_RESPONSE" >&2 && exit 1
CSRF_TOKEN=$(curl -s -H "Authorization: Bearer $TOKEN" "$SUPERSET_URL/api/v1/security/csrf_token/" | jq -r '.result')

# --- Create or Get DB ---
DB_FILTER_Q="q=$(jq -n --arg name "$DB_NAME" '{filters:[{col:"database_name",opr:"eq",value:$name}]}')"
CREATE_DB_PAYLOAD=$(jq -n \
  --arg name "$DB_NAME" --arg uri "$SQLALCHEMY_URI" --arg extra '{"show_views": true}' \
  '{database_name: $name, sqlalchemy_uri: $uri, expose_in_sqllab: true, extra: $extra}')
DB_ID=$(get_or_create_asset "database" "$DB_NAME" "$DB_FILTER_Q" "$CREATE_DB_PAYLOAD")

curl -s -X POST "$SUPERSET_URL/api/v1/database/$DB_ID/refresh" \
     -H "Authorization: Bearer $TOKEN" -H "X-CSRFToken: $CSRF_TOKEN" > /dev/null

# --- Wait for view to appear ---
FOUND=0
for i in {1..10}; do
  sleep 5
  TABLES_JSON=$(curl -s -G "$SUPERSET_URL/api/v1/database/$DB_ID/tables/" \
                --data-urlencode "q=(force:!f,schema_name:public)" \
                -H "Authorization: Bearer $TOKEN")
  MATCH=$(echo "$TABLES_JSON" | jq -r --arg t "$DATASET_TABLE_NAME" 'any(.result[]; .value == $t)')
  if [[ "$MATCH" == "true" ]]; then FOUND=1; break; fi
done
[[ $FOUND -ne 1 ]] && echo "ERROR: '$DATASET_TABLE_NAME' not found in metadata." >&2 && exit 1

# --- Dataset ---
DATASET_FILTER_Q="q=$(jq -n --arg tn "$DATASET_TABLE_NAME" '{filters:[{col:"table_name",opr:"eq",value:$tn}]}')"
CREATE_DATASET_PAYLOAD=$(jq -n \
  --arg db "$DB_ID" --arg tn "$DATASET_TABLE_NAME" --arg schema "public" \
  '{database: ($db|tonumber), table_name: $tn, schema: $schema, owners: [1]}')
DATASET_ID=$(get_or_create_asset "dataset" "$DATASET_TABLE_NAME" "$DATASET_FILTER_Q" "$CREATE_DATASET_PAYLOAD")

curl -s -X PUT "$SUPERSET_URL/api/v1/dataset/$DATASET_ID/refresh" \
     -H "Authorization: Bearer $TOKEN" -H "X-CSRFToken: $CSRF_TOKEN" > /dev/null

# --- Metrics (PATCH-based creation) ---
DESIRED_METRICS=$(jq -n '{
  "avg_profit_loss": "AVG(profit_loss)",
  "sum_profit_loss": "SUM(profit_loss)",
  "avg_fair_value": "AVG(fair_value)"
}')
EXISTING_METRICS=$(curl -s -G "$SUPERSET_URL/api/v1/dataset/$DATASET_ID" \
                     --data-urlencode 'q={"columns":["metrics"]}' \
                     -H "Authorization: Bearer $TOKEN" \
                   | jq '.result.metrics // []')

for metric_name in $(echo "$DESIRED_METRICS" | jq -r 'keys[]'); do
  if echo "$EXISTING_METRICS" \
       | jq -e --arg name "$metric_name" 'any(.metric_name == $name)' > /dev/null; then
    continue
  fi
  expression=$(jq -r --arg k "$metric_name" '.[$k]' <<<"$DESIRED_METRICS")
  verbose_name=$(echo "$metric_name" | sed 's/_/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')

  metric_payload=$(jq -n \
    --arg mn "$metric_name" \
    --arg expr "$expression" \
    --arg vn "$verbose_name" \
    '{metric_name: $mn, expression: $expr, verbose_name: $vn, metric_type: "expression"}')

  echo "--- Creating metric $metric_name ---" >&2
  curl -s -X PATCH "$SUPERSET_URL/api/v1/dataset/$DATASET_ID" \
       -H "Authorization: Bearer $TOKEN" \
       -H "X-CSRFToken: $CSRF_TOKEN" \
       -H "Content-Type: application/json" \
       -d "{\"metrics\":[$metric_payload]}" \
  | jq .
done

# --- Chart: Profit & Loss Over Time ---
CHART_1_NAME="Profit & Loss Over Time"
CHART_1_FILTER_Q="q=$(jq -n --arg name "$CHART_1_NAME" '{filters:[{col:"slice_name",opr:"eq",value:$name}]}')"
CHART_1_PARAMS=$(jq -n --argjson ds_id "$DATASET_ID" '{
  "viz_type": "line",
  "datasource": "\($ds_id)__table",
  "granularity_sqla": "last_update",
  "time_range": "Last week",
  "metrics": ["avg_profit_loss"],
  "groupby": ["league"],
  "row_limit": 1000,
  "time_grain_sqla": "PT1M"
}')
CREATE_CHART_1_PAYLOAD=$(jq -n --arg name "$CHART_1_NAME" --argjson ds_id "$DATASET_ID" --argjson params "$CHART_1_PARAMS" '{
  "slice_name": $name,
  "viz_type": "line",
  "datasource_id": $ds_id,
  "datasource_type": "table",
  "params": ($params | tostring),
  "owners": [1]
}')
CHART_1_ID=$(get_or_create_asset "chart" "$CHART_1_NAME" "$CHART_1_FILTER_Q" "$CREATE_CHART_1_PAYLOAD")

# --- Chart: Risk Level Distribution ---
CHART_2_NAME="Risk Level Distribution"
CHART_2_FILTER_Q="q=$(jq -n --arg name "$CHART_2_NAME" '{filters:[{col:"slice_name",opr:"eq",value:$name}]}')"
CHART_2_PARAMS=$(jq -n --argjson ds_id "$DATASET_ID" '{
  "viz_type": "pie",
  "datasource": "\($ds_id)__table",
  "metric": "sum_profit_loss",
  "groupby": ["risk_level"],
  "time_range": "No filter",
  "color_scheme": "supersetColors"
}')
CREATE_CHART_2_PAYLOAD=$(jq -n --arg name "$CHART_2_NAME" --argjson ds_id "$DATASET_ID" --argjson params "$CHART_2_PARAMS" '{
  "slice_name": $name,
  "viz_type": "pie",
  "datasource_id": $ds_id,
  "datasource_type": "table",
  "params": ($params | tostring),
  "owners": [1]
}')
CHART_2_ID=$(get_or_create_asset "chart" "$CHART_2_NAME" "$CHART_2_FILTER_Q" "$CREATE_CHART_2_PAYLOAD")

# --- Chart: Market Prices by Bookmaker ---
CHART_3_NAME="Market Prices by Bookmaker"
CHART_3_FILTER_Q="q=$(jq -n --arg name "$CHART_3_NAME" '{filters:[{col:"slice_name",opr:"eq",value:$name}]}')"
CHART_3_PARAMS=$(jq -n --argjson ds_id "$DATASET_ID" '{
  "viz_type": "bar",
  "datasource": "\($ds_id)__table",
  "metrics": ["market_price"],
  "groupby": ["bookmaker"],
  "time_range": "No filter",
  "color_scheme": "supersetColors"
}')
CREATE_CHART_3_PAYLOAD=$(jq -n --arg name "$CHART_3_NAME" --argjson ds_id "$DATASET_ID" --argjson params "$CHART_3_PARAMS" '{
  "slice_name": $name,
  "viz_type": "bar",
  "datasource_id": $ds_id,
  "datasource_type": "table",
  "params": ($params | tostring),
  "owners": [1]
}')
CHART_3_ID=$(get_or_create_asset "chart" "$CHART_3_NAME" "$CHART_3_FILTER_Q" "$CREATE_CHART_3_PAYLOAD")

echo "✅ Superset charts created:"
echo " - $CHART_1_NAME: $SUPERSET_URL/explore/?slice_id=$CHART_1_ID"
echo " - $CHART_2_NAME: $SUPERSET_URL/explore/?slice_id=$CHART_2_ID"
echo " - $CHART_3_NAME: $SUPERSET_URL/explore/?slice_id=$CHART_3_ID"

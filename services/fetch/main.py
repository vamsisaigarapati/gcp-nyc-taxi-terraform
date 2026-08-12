import os
from datetime import date

import functions_framework
import requests
from flask import jsonify
from google.cloud import storage

BUCKET_NAME = os.environ["BUCKET_NAME"]
BASE_URL = "https://d37ci6vzurychx.cloudfront.net/trip-data"


def _previous_month():
    today = date.today()
    year, month = today.year, today.month - 1
    if month == 0:
        year, month = year - 1, 12
    return year, month


@functions_framework.http
def fetch_raw_data(request):
    """HTTP-triggered Cloud Function.

    Accepts optional `year`/`month` (query params or JSON body). When
    omitted — as on the monthly Cloud Scheduler trigger, whose HTTP body is
    static — defaults to last month, since NYC TLC publishes with a lag.
    Downloads the corresponding yellow taxi parquet file and streams it
    straight into the raw GCS bucket.
    """
    request_json = request.get_json(silent=True) or {}
    request_args = request.args

    year = request_json.get("year", request_args.get("year"))
    month = request_json.get("month", request_args.get("month"))

    if year is None or month is None:
        year, month = _previous_month()

    try:
        year = int(year)
        month = int(month)
    except (TypeError, ValueError):
        return jsonify({"error": "'year' and 'month' must be integers"}), 400

    if not (1 <= month <= 12):
        return jsonify({"error": "'month' must be between 1 and 12"}), 400

    url = f"{BASE_URL}/yellow_tripdata_{year}-{month:02}.parquet"
    blob_name = f"rides_{year}_{month:02}.parquet"

    response = requests.get(url, stream=True, timeout=60)
    if response.status_code != 200:
        return jsonify({"error": f"{url} is not available"}), 502

    storage_client = storage.Client()
    bucket = storage_client.bucket(BUCKET_NAME)
    blob = bucket.blob(blob_name)

    with blob.open("wb", content_type="application/octet-stream") as f:
        for chunk in response.iter_content(chunk_size=8 * 1024 * 1024):
            if chunk:
                f.write(chunk)

    gcs_path = f"gs://{BUCKET_NAME}/{blob_name}"
    print(f"Successfully fetched: {gcs_path}")
    return jsonify({"path": gcs_path, "bucket": BUCKET_NAME, "blob": blob_name}), 200

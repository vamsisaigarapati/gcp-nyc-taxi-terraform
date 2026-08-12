import json
import sys
import urllib.error
import urllib.request

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

CATALOG = "lakehouse"
DATABASE = "nyc_taxi_tf"
TABLE = "yellow_tripdata"


def _get_access_token():
    req = urllib.request.Request(
        "http://metadata.google.internal/computeMetadata/v1/instance/"
        "service-accounts/default/token",
        headers={"Metadata-Flavor": "Google"},
    )
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)["access_token"]


def _api_request(method, url, token, project_id, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("x-goog-user-project", project_id)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read()
        return e.code, json.loads(raw) if raw else {}


def sync_rest_catalog_pointer(project_id, region, blms_catalog, database, table, token):
    """Re-point the native Iceberg REST catalog (used by tools like Gravitino
    and by direct catalog queries) at this table's current metadata
    location. Without this, that catalog stays frozen at whatever snapshot
    was last registered, silently going stale on every subsequent append.
    Best-effort: a failure here logs a warning but does not fail the job,
    since the real write (above) already succeeded and is the source of
    truth.
    """
    try:
        rest_catalog = f"{blms_catalog}_rest"

        hive_url = (
            f"https://biglake.googleapis.com/v1/projects/{project_id}/locations/"
            f"{region}/catalogs/{blms_catalog}/databases/{database}/tables/{table}"
        )
        status, body = _api_request("GET", hive_url, token, project_id)
        if status != 200:
            print(f"WARN: could not read source table metadata ({status}): {body}")
            return None
        metadata_location = body["hiveOptions"]["parameters"]["metadata_location"]

        prefix = f"projects/{project_id}/catalogs/{rest_catalog}"
        base = f"https://biglake.googleapis.com/iceberg/v1/restcatalog/v1/{prefix}"

        # namespace may already exist — 409 is fine, ignore it
        _api_request("POST", f"{base}/namespaces", token, project_id, {"namespace": [database]})

        # drop the stale pointer if one exists (404 on first-ever run is fine)
        _api_request("DELETE", f"{base}/namespaces/{database}/tables/{table}", token, project_id)

        status, body = _api_request(
            "POST",
            f"{base}/namespaces/{database}/register",
            token,
            project_id,
            {"name": table, "metadata-location": metadata_location},
        )
        if status == 200:
            print(f"REST catalog pointer updated -> {metadata_location}")
        else:
            print(f"WARN: REST catalog pointer update failed ({status}): {body}")

        return metadata_location
    except Exception as e:
        print(f"WARN: REST catalog sync failed, continuing: {e}")
        return None


def sync_bigquery_external_table(project_id, bq_connection, bq_dataset, table, metadata_location, token):
    """Point a BigLake external table at the Iceberg metadata this run just
    produced, so `bq_dataset.table` stays queryable from BigQuery without a
    manual `bq mk` step. Best-effort, same rationale as the REST catalog
    sync above — the Iceberg write is already durable regardless.
    """
    if not metadata_location:
        print("WARN: no metadata location to sync to BigQuery, skipping")
        return

    ddl = (
        f"CREATE OR REPLACE EXTERNAL TABLE `{bq_dataset}.{table}` "
        f"WITH CONNECTION `{bq_connection}` "
        f"OPTIONS (file_format = 'PARQUET', table_format = 'ICEBERG', "
        f"storage_uri = '{metadata_location}')"
    )

    url = f"https://bigquery.googleapis.com/bigquery/v2/projects/{project_id}/jobs"
    body = {"configuration": {"query": {"query": ddl, "useLegacySql": False}}}
    status, resp = _api_request("POST", url, token, project_id, body)
    if status in (200, 201):
        print(f"BigQuery external table {bq_dataset}.{table} synced -> {metadata_location}")
    else:
        print(f"WARN: BigQuery external table sync failed ({status}): {resp}")


def main():
    if len(sys.argv) < 2:
        raise ValueError("Usage: process_to_iceberg.py <gcs_source_parquet_path>")

    source_path = sys.argv[1]
    full_table_name = f"{CATALOG}.{DATABASE}.{TABLE}"

    spark = SparkSession.builder.appName("yellow-taxi-to-iceberg").getOrCreate()

    project_id = spark.conf.get("spark.sql.catalog.lakehouse.gcp_project")
    region = spark.conf.get("spark.sql.catalog.lakehouse.gcp_location")
    blms_catalog = spark.conf.get("spark.sql.catalog.lakehouse.blms_catalog")
    bq_connection = spark.conf.get("spark.taxi.bq_connection")
    bq_dataset = spark.conf.get("spark.taxi.bq_dataset")

    spark.sql(f"CREATE NAMESPACE IF NOT EXISTS {CATALOG}.{DATABASE}")

    df = spark.read.parquet(source_path)

    df = (
        df.withColumn("VendorID", F.col("VendorID").cast("int"))
        .withColumn("passenger_count", F.col("passenger_count").cast("int"))
        .withColumn("trip_year", F.year("tpep_pickup_datetime"))
        .withColumn("trip_month", F.month("tpep_pickup_datetime"))
        .withColumn("source_file", F.lit(source_path))
        .withColumn("ingested_at", F.current_timestamp())
    )

    if spark.catalog.tableExists(full_table_name):
        print(f"{full_table_name} exists — appending data from {source_path}")
        df.writeTo(full_table_name).append()
    else:
        print(f"{full_table_name} does not exist — creating it from {source_path}")
        (
            df.writeTo(full_table_name)
            .using("iceberg")
            .partitionedBy("trip_year", "trip_month")
            .create()
        )

    print(f"Done. Row count written: {df.count()}")

    token = _get_access_token()
    metadata_location = sync_rest_catalog_pointer(
        project_id, region, blms_catalog, DATABASE, TABLE, token
    )
    sync_bigquery_external_table(project_id, bq_connection, bq_dataset, TABLE, metadata_location, token)

    spark.stop()


if __name__ == "__main__":
    main()

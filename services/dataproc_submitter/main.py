import os
import time

import functions_framework
from google.cloud import dataproc_v1

PROJECT_ID = os.environ["PROJECT_ID"]
REGION = os.environ.get("REGION", "us-central1")
RAW_BUCKET = os.environ["RAW_BUCKET"]
SUBNETWORK = os.environ["DATAPROC_SUBNETWORK"]
SERVICE_ACCOUNT = os.environ["DATAPROC_SERVICE_ACCOUNT"]
STAGING_BUCKET = os.environ["STAGING_BUCKET"]
PYSPARK_FILE_URI = os.environ["PYSPARK_FILE_URI"]
ICEBERG_RUNTIME_JAR_URI = os.environ.get(
    "ICEBERG_RUNTIME_JAR_URI",
    "gs://spark-lib/iceberg/iceberg-spark-runtime-3.5_2.12-1.6.1.jar",
)
BIGLAKE_JAR_URI = os.environ.get(
    "BIGLAKE_JAR_URI",
    "gs://spark-lib/biglake/biglake-catalog-iceberg1.5.1-0.1.2-with-dependencies.jar",
)
BLMS_CATALOG = os.environ["BLMS_CATALOG"]
ICEBERG_WAREHOUSE = os.environ["ICEBERG_WAREHOUSE"]
BQ_CONNECTION = os.environ["BQ_CONNECTION"]
BQ_DATASET = os.environ["BQ_DATASET"]


@functions_framework.cloud_event
def trigger_spark_job(cloud_event):
    """Eventarc-triggered Cloud Function.

    Fires on every new object finalized in RAW_BUCKET. Filters down to
    parquet files, then submits a Dataproc Serverless Spark batch that
    loads that single file into the Iceberg lakehouse table via the
    BigLake Metastore catalog.
    """
    data = cloud_event.data
    bucket = data.get("bucket")
    name = data.get("name")

    if bucket != RAW_BUCKET:
        print(f"Ignoring event from unexpected bucket: {bucket}")
        return

    if not name or not name.endswith(".parquet"):
        print(f"Ignoring non-parquet object: {name}")
        return

    gcs_uri = f"gs://{bucket}/{name}"
    stem = name.rsplit(".", 1)[0].replace("_", "-").lower()
    batch_id = f"load-{stem}-{int(time.time())}"

    client = dataproc_v1.BatchControllerClient(
        client_options={"api_endpoint": f"{REGION}-dataproc.googleapis.com:443"}
    )

    batch = dataproc_v1.Batch()
    batch.pyspark_batch.main_python_file_uri = PYSPARK_FILE_URI
    batch.pyspark_batch.args.extend([gcs_uri])
    batch.pyspark_batch.jar_file_uris.extend([ICEBERG_RUNTIME_JAR_URI, BIGLAKE_JAR_URI])
    batch.runtime_config.properties.update(
        {
            "spark.sql.extensions": "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
            "spark.sql.catalog.lakehouse": "org.apache.iceberg.spark.SparkCatalog",
            "spark.sql.catalog.lakehouse.catalog-impl": "org.apache.iceberg.gcp.biglake.BigLakeCatalog",
            "spark.sql.catalog.lakehouse.gcp_project": PROJECT_ID,
            "spark.sql.catalog.lakehouse.gcp_location": REGION,
            "spark.sql.catalog.lakehouse.blms_catalog": BLMS_CATALOG,
            "spark.sql.catalog.lakehouse.warehouse": ICEBERG_WAREHOUSE,
            "spark.sql.defaultCatalog": "lakehouse",
            "spark.taxi.bq_connection": f"{PROJECT_ID}.{REGION}.{BQ_CONNECTION}",
            "spark.taxi.bq_dataset": f"{PROJECT_ID}.{BQ_DATASET}",
        }
    )
    batch.environment_config.execution_config.subnetwork_uri = SUBNETWORK
    batch.environment_config.execution_config.service_account = SERVICE_ACCOUNT
    batch.environment_config.execution_config.staging_bucket = STAGING_BUCKET

    request = dataproc_v1.CreateBatchRequest(
        parent=f"projects/{PROJECT_ID}/regions/{REGION}",
        batch=batch,
        batch_id=batch_id,
    )

    client.create_batch(request=request)
    print(f"Submitted Dataproc Serverless batch '{batch_id}' for {gcs_uri}")

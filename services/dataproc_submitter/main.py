import json
import os
import time
from pathlib import Path

import functions_framework
from google.cloud import dataproc_v1

PROJECT_ID = os.environ["PROJECT_ID"]
REGION = os.environ.get("REGION", "us-central1")
RAW_BUCKET = os.environ["RAW_BUCKET"]
SUBNETWORK = os.environ["DATAPROC_SUBNETWORK"]
SERVICE_ACCOUNT = os.environ["DATAPROC_SERVICE_ACCOUNT"]
STAGING_BUCKET = os.environ["STAGING_BUCKET"]
PYSPARK_FILE_URI = os.environ["PYSPARK_FILE_URI"]
BQ_TABLE = os.environ["BQ_TABLE"]  # fully qualified: project.dataset.table

# Compute shape (machine sizing, Spark properties, runtime image version)
# lives in its own file rather than here, so tuning the job doesn't mean
# editing the code that submits it. See batch_config.json for why.
_CONFIG_PATH = Path(__file__).parent / "batch_config.json"
with open(_CONFIG_PATH) as f:
    _batch_config = json.load(f)


@functions_framework.cloud_event
def trigger_spark_job(cloud_event):
    """Eventarc-triggered Cloud Function.

    Fires on every new object finalized in RAW_BUCKET. Filters down to
    parquet files, then submits a Dataproc Serverless Spark batch that
    loads that single file straight into a native BigQuery table.
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
    batch.pyspark_batch.args.extend([gcs_uri, BQ_TABLE, STAGING_BUCKET])

    batch.runtime_config.version = _batch_config["runtime_version"]
    batch.runtime_config.properties.update(_batch_config["properties"])

    batch.environment_config.execution_config.subnetwork_uri = SUBNETWORK
    batch.environment_config.execution_config.service_account = SERVICE_ACCOUNT
    batch.environment_config.execution_config.staging_bucket = STAGING_BUCKET

    request = dataproc_v1.CreateBatchRequest(
        parent=f"projects/{PROJECT_ID}/regions/{REGION}",
        batch=batch,
        batch_id=batch_id,
    )

    client.create_batch(request=request)
    print(f"Submitted Dataproc Serverless batch '{batch_id}' for {gcs_uri} -> {BQ_TABLE}")

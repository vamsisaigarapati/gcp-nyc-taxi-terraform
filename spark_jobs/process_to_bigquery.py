import sys

from pyspark.sql import SparkSession
from pyspark.sql import functions as F


def main():
    if len(sys.argv) < 4:
        raise ValueError(
            "Usage: process_to_bigquery.py <gcs_source_parquet_path> "
            "<project.dataset.table> <temp_gcs_bucket>"
        )

    source_path, bq_table, temp_bucket = sys.argv[1], sys.argv[2], sys.argv[3]

    spark = SparkSession.builder.appName("yellow-taxi-to-bigquery").getOrCreate()

    df = spark.read.parquet(source_path)

    df = (
        df.withColumn("VendorID", F.col("VendorID").cast("int"))
        .withColumn("passenger_count", F.col("passenger_count").cast("int"))
        .withColumn("trip_year", F.year("tpep_pickup_datetime"))
        .withColumn("trip_month", F.month("tpep_pickup_datetime"))
        .withColumn("source_file", F.lit(source_path))
        .withColumn("ingested_at", F.current_timestamp())
    )

    # createDisposition=CREATE_IF_NEEDED lets BigQuery infer the schema from
    # this DataFrame on the very first run. The table's *shape* is therefore
    # owned by this job, not by Terraform — NYC TLC has changed the source
    # parquet schema across years (e.g. airport_fee, cbd_congestion_fee were
    # added later), so hardcoding a schema in HCL would drift out of date.
    # The dataset itself is still Terraform-managed; only the table isn't.
    (
        df.write.format("bigquery")
        .option("table", bq_table)
        .option("temporaryGcsBucket", temp_bucket)
        .option("createDisposition", "CREATE_IF_NEEDED")
        .mode("append")
        .save()
    )

    print(f"Done. Wrote {df.count()} rows from {source_path} to {bq_table}")

    spark.stop()


if __name__ == "__main__":
    main()

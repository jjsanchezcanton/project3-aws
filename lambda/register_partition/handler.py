"""S3 ObjectCreated (landing/) -> copy to bronze/ partition path -> glue:CreatePartition.

Validates by key pattern + object size only; does not parse parquet content (ADR-011).
"""

import json
import logging
import os
import re
import urllib.parse

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")
glue = boto3.client("glue")

KEY_PATTERN = re.compile(r"^landing/yellow_tripdata_(\d{4})-(\d{2})\.parquet$")

GLUE_DATABASE = os.environ["GLUE_DATABASE"]
GLUE_TABLE = os.environ["GLUE_TABLE"]


def register_partition(bucket: str, year: str, month: str, partition_location: str) -> None:
    table = glue.get_table(DatabaseName=GLUE_DATABASE, Name=GLUE_TABLE)["Table"]
    storage_descriptor = table["StorageDescriptor"]
    storage_descriptor["Location"] = partition_location

    try:
        glue.create_partition(
            DatabaseName=GLUE_DATABASE,
            TableName=GLUE_TABLE,
            PartitionInput={
                "Values": [year, month],
                "StorageDescriptor": storage_descriptor,
            },
        )
    except glue.exceptions.AlreadyExistsException:
        logger.info(json.dumps({"event": "partition_already_exists", "year": year, "month": month}))


def lambda_handler(event, context):
    for record in event["Records"]:
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

        match = KEY_PATTERN.match(key)
        if not match:
            logger.warning(json.dumps({"event": "skip_invalid_key", "key": key}))
            continue

        try:
            head = s3.head_object(Bucket=bucket, Key=key)
        except ClientError as exc:
            logger.warning(json.dumps({"event": "skip_head_object_failed", "key": key, "error": str(exc)}))
            continue

        if head["ContentLength"] <= 0:
            logger.warning(json.dumps({"event": "skip_empty_object", "key": key}))
            continue

        year, month = match.groups()
        filename = key.rsplit("/", 1)[-1]
        dest_key = f"bronze/yellow_taxi/year={year}/month={month}/{filename}"

        s3.copy_object(Bucket=bucket, Key=dest_key, CopySource={"Bucket": bucket, "Key": key})

        partition_location = f"s3://{bucket}/bronze/yellow_taxi/year={year}/month={month}/"
        register_partition(bucket, year, month, partition_location)

        logger.info(
            json.dumps(
                {
                    "event": "partition_registered",
                    "year": year,
                    "month": month,
                    "location": partition_location,
                }
            )
        )

    return {"statusCode": 200}

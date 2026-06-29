"""Upload the downloaded parquet to s3://<bucket>/landing/ — fires the ingest Lambda."""

import argparse
import logging
import os
from pathlib import Path

import boto3

logging.basicConfig(level=logging.INFO, format="%(message)s")
logger = logging.getLogger(__name__)

DATA_DIR = Path(__file__).resolve().parent.parent / "data"


def upload(year: int, month: int) -> None:
    bucket = os.environ["DATA_BUCKET"]
    region = os.environ["AWS_REGION"]

    filename = f"yellow_tripdata_{year:04d}-{month:02d}.parquet"
    local_path = DATA_DIR / filename
    key = f"landing/{filename}"

    s3 = boto3.client("s3", region_name=region)
    s3.upload_file(str(local_path), bucket, key)

    head = s3.head_object(Bucket=bucket, Key=key)
    logger.info("Uploaded s3://%s/%s (ETag %s)", bucket, key, head["ETag"])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--year", type=int, default=2024)
    parser.add_argument("--month", type=int, default=1)
    args = parser.parse_args()
    upload(args.year, args.month)


if __name__ == "__main__":
    main()

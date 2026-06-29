"""Download one month of NYC TLC Yellow Taxi parquet to data/, idempotently."""

import argparse
import logging
from pathlib import Path

import requests

logging.basicConfig(level=logging.INFO, format="%(message)s")
logger = logging.getLogger(__name__)

BASE_URL = "https://d37ci6vzurychx.cloudfront.net/trip-data"
DATA_DIR = Path(__file__).resolve().parent.parent / "data"


def download(year: int, month: int) -> Path:
    filename = f"yellow_tripdata_{year:04d}-{month:02d}.parquet"
    url = f"{BASE_URL}/{filename}"
    dest = DATA_DIR / filename

    head = requests.head(url, allow_redirects=True, timeout=30)
    head.raise_for_status()
    remote_size = int(head.headers["Content-Length"])

    if dest.exists() and dest.stat().st_size == remote_size:
        logger.info("Up to date: %s (%d bytes)", dest, remote_size)
        return dest

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with requests.get(url, stream=True, timeout=30) as resp:
        resp.raise_for_status()
        with dest.open("wb") as f:
            for chunk in resp.iter_content(chunk_size=1024 * 1024):
                f.write(chunk)

    actual_size = dest.stat().st_size
    logger.info("Downloaded: %s (%d bytes)", dest, actual_size)
    return dest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--year", type=int, default=2024)
    parser.add_argument("--month", type=int, default=1)
    args = parser.parse_args()
    download(args.year, args.month)


if __name__ == "__main__":
    main()

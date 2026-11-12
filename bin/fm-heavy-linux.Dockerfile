# fm-heavy-linux:2 - portable Linux test image (Node runtimes are mounted per job).
# Build on the Mac only after owner approval, from this repository's root:
#   flock -n /tmp/fm-heavy.lock docker build -t fm-heavy-linux:2 - < bin/fm-heavy-linux.Dockerfile
# This uses the existing Docker context; never change Colima or other images.
FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 git ffmpeg tesseract-ocr tesseract-ocr-eng coreutils ca-certificates curl build-essential \
 && rm -rf /var/lib/apt/lists/*

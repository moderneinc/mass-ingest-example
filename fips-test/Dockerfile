# Thin test layer on top of the production Dockerfile.fips image.
# Adds small Gradle test projects (one per JDK version) so that
# `mod build /repos` exercises JDK 8, 11, 17, 21, and 25 under FIPS.
#
# Built by the Makefile — the base image is built from ../Dockerfile.fips first.

ARG BASE_IMAGE=mass-ingest-fips
FROM ${BASE_IMAGE}

WORKDIR /repos
COPY repos/ .
RUN git config --global user.email "test@test" && \
    git config --global user.name "test" && \
    for d in */; do \
      cd "/repos/$d" && \
      git init -q && \
      git remote add origin "https://github.com/example/$(basename "$d").git" && \
      git add -A && \
      git commit -q -m "init"; \
    done

#!/usr/bin/env bash

set -Eeuo pipefail

TEST_PASSWORD="$(cat /run/secrets/postgres_test_password)"
DEV_PASSWORD="$(cat /run/secrets/postgres_dev_password)"

psql \
  --set=ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  --set=test_password="$TEST_PASSWORD" \
  --set=dev_password="$DEV_PASSWORD" <<'SQL'
CREATE ROLE ignition_test
    LOGIN
    PASSWORD :'test_password';

CREATE DATABASE ignition_test
    OWNER ignition_test;

CREATE ROLE ignition_dev
    LOGIN
    PASSWORD :'dev_password';

CREATE DATABASE ignition_dev
    OWNER ignition_dev;
SQL
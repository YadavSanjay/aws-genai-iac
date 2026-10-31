#!/usr/bin/env bash
# Create the one-time Terraform remote-state backend (S3 bucket only).
# Chicken-and-egg: this must exist BEFORE any `terragrunt` run.
# Values must match infra/account.hcl.
#
# Locking is S3-native (`use_lockfile = true` in infra/root.hcl): the backend
# takes a conditional-write lock on a `<key>.tflock` object beside each state
# file. No DynamoDB table is needed — `dynamodb_table` is deprecated.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
BUCKET="${STATE_BUCKET:-aws-genai-iac-tfstate}"

echo ">> Creating state bucket: ${BUCKET} (${REGION})"
if [[ "${REGION}" == "us-east-1" ]]; then
  aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}"
else
  aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" \
    --create-bucket-configuration LocationConstraint="${REGION}"
fi

aws s3api put-bucket-versioning --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "${BUCKET}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'
aws s3api put-public-access-block --bucket "${BUCKET}" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo ">> Done. Backend ready (S3-native locking; no lock table)."

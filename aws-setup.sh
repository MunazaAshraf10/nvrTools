#!/usr/bin/env bash
# The AWS half. Run once, from a machine with admin credentials.
#
#   ./aws-setup.sh
#
# Creates the training bucket and an IAM user whose only power is to add footage
# to it. Prints an access key at the end: that key goes on the court box and
# nowhere else.
#
# Idempotent. Safe to run again; it skips what already exists.
set -euo pipefail

REGION="${REGION:-ap-southeast-1}"
IAM_USER="${IAM_USER:-padelytix-court-box}"
POLICY_NAME="${POLICY_NAME:-padelytix-court-box-put}"


command -v aws >/dev/null || { echo "aws cli not installed" >&2; exit 1; }

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# Suffixed with the account id, because S3 bucket names are global: without it,
# the name is one somebody else may already have taken. Matches the app's own
# padelytix-media-<account> and padelytix-reports-<account>.
BUCKET="${BUCKET:-padelytix-training-${ACCOUNT}}"

echo "==> account ${ACCOUNT}, region ${REGION}, bucket ${BUCKET}"

if [[ "$(aws sts get-caller-identity --query Arn --output text)" == *":root" ]]; then
    echo "!!  You are running as ROOT. It will work, but a root key cannot be"
    echo "!!  scoped or safely revoked. Make an IAM admin user and use that."
fi

# ---------------------------------------------------------------- the bucket

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    echo "==> bucket ${BUCKET} exists"
else
    echo "==> creating ${BUCKET}"
    aws s3api create-bucket \
        --bucket "$BUCKET" \
        --region "$REGION" \
        --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
fi

# Footage of people playing sport. It is never public, and there is no reason a
# bucket policy should ever be able to make it public by accident.
echo "==> blocking public access"
aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

echo "==> encryption at rest"
aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

# Deliberately NO lifecycle rule. This is the one bucket that keeps things: the
# app's media bucket deletes frames after 48 hours, and a rule copied over from
# there would quietly eat the training set.
echo "==> no lifecycle rule, on purpose (this bucket keeps everything)"

# ------------------------------------------------------------------ the user

POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/${POLICY_NAME}"

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    echo "==> policy ${POLICY_NAME} exists"
else
    echo "==> creating policy ${POLICY_NAME}"
    aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --description "Court box: add training footage, nothing else" \
        --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"AddFootageOnly\",\"Effect\":\"Allow\",\"Action\":\"s3:PutObject\",\"Resource\":\"arn:aws:s3:::${BUCKET}/*\"}]}" >/dev/null
fi

if aws iam get-user --user-name "$IAM_USER" >/dev/null 2>&1; then
    echo "==> user ${IAM_USER} exists"
else
    echo "==> creating user ${IAM_USER}"
    aws iam create-user --user-name "$IAM_USER" >/dev/null
fi

echo "==> attaching policy"
aws iam attach-user-policy --user-name "$IAM_USER" --policy-arn "$POLICY_ARN"

# ------------------------------------------------------------------- the key

# The box sits in a public sports venue and anybody could walk off with it. This
# key can add footage. It cannot read the bucket, cannot delete from it, and
# cannot see any other bucket. That is the whole point of the policy.
EXISTING=$(aws iam list-access-keys --user-name "$IAM_USER" \
    --query 'AccessKeyMetadata[].AccessKeyId' --output text)

if [[ -n "$EXISTING" ]]; then
    cat <<EOF

==> ${IAM_USER} already has a key: ${EXISTING}

    AWS will not show you its secret again. If you still have it, use it. If you
    do not, rotate:

        aws iam delete-access-key --user-name ${IAM_USER} --access-key-id ${EXISTING}
        ./aws-setup.sh

EOF
    exit 0
fi

echo "==> creating an access key"
KEY_JSON=$(aws iam create-access-key --user-name "$IAM_USER")
KEY_ID=$(echo "$KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')
KEY_SECRET=$(echo "$KEY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')

cat <<EOF

==> done.

    Bucket   s3://${BUCKET}  (${REGION}, private, encrypted, no lifecycle rule)
    User     ${IAM_USER}     (s3:PutObject on that bucket, and nothing else)

    This secret is shown ONCE. AWS cannot show it to you again.
    Put it on the court box, in /var/lib/padelytix/.aws/credentials:

        [default]
        aws_access_key_id = ${KEY_ID}
        aws_secret_access_key = ${KEY_SECRET}

        [default]
        region = ${REGION}

    Then prove it, on the box:

        sudo -u padelytix aws s3 cp /etc/hostname s3://${BUCKET}/_test.txt

    Do not commit it. Do not paste it into a chat window.

EOF

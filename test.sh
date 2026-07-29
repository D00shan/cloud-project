jq '.Statement[] | {Sid, Action, Resource}' \
  infrastructure/build/generated-config/lambda-s3-policy.json

jq '.Statement[] | {Sid, Action, Resource}' \
  infrastructure/build/generated-config/lambda-sqs-policy.json
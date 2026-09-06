# Populated from the bootstrap stack's `backend_config` output.
#
#   cd ../../bootstrap
#   terraform output -raw backend_config
#
# `use_lockfile` is Terraform 1.10+ native S3 locking. It replaces the DynamoDB
# table older guides tell you to create — one less resource, one less IAM policy,
# one less thing to pay for.

terraform {
  backend "s3" {
    bucket       = "REPLACE_ME_FROM_BOOTSTRAP_OUTPUT"
    key          = "dev/terraform.tfstate"
    region       = "eu-west-2"
    encrypt      = true
    use_lockfile = true
  }
}

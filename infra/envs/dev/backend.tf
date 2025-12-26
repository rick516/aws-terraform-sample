terraform {
  backend "s3" {
    # TODO: bootstrap の output(tfstate_bucket) の値に置き換える
    bucket       = "BUCKET_NAME"
    key          = "dev/terraform.tfstate"
    region       = "ap-northeast-1"

    # TODO: state locking（S3 lockfile）を有効化する
    use_lockfile = true
  }
}

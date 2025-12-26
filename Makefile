# 使い方:
#   make bootstrap-apply
#   make apply
#   make destroy-all
#
# 注意:
# - destroy-all は "dev環境 → bootstrap" の順で消します
# - main(env/dev) を消す前に bootstrap を消すと、stateが消えて撤収できなくなることがあります

AWS_PROFILE ?= aws-terraform-sample
AWS_REGION  ?= ap-northeast-1

.PHONY: bootstrap-apply bootstrap-destroy apply plan destroy destroy-all

bootstrap-apply:
	cd infra/bootstrap && terraform init && terraform apply -auto-approve

bootstrap-destroy:
	cd infra/bootstrap && terraform destroy -auto-approve

plan:
	cd infra/envs/dev && terraform init && terraform plan

apply:
	cd infra/envs/dev && terraform init && terraform apply

destroy:
	cd infra/envs/dev && terraform init && terraform destroy -auto-approve

destroy-all: destroy bootstrap-destroy

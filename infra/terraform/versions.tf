# 메타 갤러리 인프라 - Terraform/프로바이더 버전 고정
#
# 주의: AWS 자격증명이 없어 `terraform init`을 실행하지 못했다.
#       따라서 아래 버전 제약과 리소스 스키마는 "문서 기준"이며 실제 검증되지 않았다.
#       최초 적용 시 `terraform init` → `terraform validate` → `terraform plan`
#       순서로 반드시 확인한다. (infra/terraform/README.md 참고)

terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # 1단계는 로컬 state 전제다. 지금은 state를 보관할 S3 버킷 자체가
  # 이 코드로 만들어지므로(닭-달걀 문제) 백엔드를 비워 둔다.
  # S3 백엔드 전환 절차는 README의 "state를 S3로 옮기기"를 따른다.
  #
  # backend "s3" {
  #   bucket       = "<TFSTATE_BUCKET>"
  #   key          = "meta-gallery/terraform.tfstate"
  #   region       = "ap-southeast-2"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

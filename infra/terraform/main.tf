# 메타 갤러리 인프라 - 프로바이더와 공통 로컬값
#
# 이 디렉터리가 만드는 것 (계획서 2장 항목 2 범위):
#   - Lightsail 인스턴스 1대 + 고정 IP + 방화벽(80/443/22)
#   - S3 버킷 3개(에셋 운영/개발, 백업) + 비공개·암호화·버전관리·수명주기
#
# 이 디렉터리가 만들지 않는 것:
#   - 인스턴스 내부 구성(nginx/PostgreSQL/systemd) → infra/server/ (팀원 3)
#   - DuckDNS·인증서 → infra/duckdns/, scripts/ops/ (팀원 4)
#   - GitHub Actions·배포 스크립트 → .github/, scripts/deploy/ (팀원 1)

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = local.common_tags
  }
}

# 계정 ID를 코드에 하드코딩하지 않기 위해 런타임에 조회한다.
# (버킷 정책의 리소스 ARN은 버킷 이름만 쓰므로 계정 ID가 필요 없고,
#  이 데이터는 버킷 이름 접미사 안내 출력에만 쓴다.)
data "aws_caller_identity" "current" {}

locals {
  common_tags = merge(
    {
      Project   = var.project_name
      ManagedBy = "terraform"
      Repo      = "meta-gallery"
    },
    var.extra_tags
  )

  # 버킷 이름 접미사 규칙(계획서 1-4): 기본은 접미사 없음.
  # 전역 이름이 선점됐을 때만 계정 ID 뒤 4자리를 붙인다.
  bucket_suffix = var.bucket_name_suffix == "" ? "" : "-${var.bucket_name_suffix}"

  # 버킷 3개 정의. 공통 보안 설정(비공개·버전관리·암호화·TLS 강제)은
  # s3.tf에서 이 map을 for_each로 돌며 똑같이 적용한다.
  # purpose 는 S3 Purpose 태그 값으로 쓰인다.
  # S3 태그 값은 유니코드 문자·숫자·공백과 _ . : / = + - @ 만 허용한다.
  # 가운뎃점(·), 괄호, 쉼표를 쓰면 CreateBucket 이 InvalidTag 로 거부한다
  # (2026-11-13 실제 실패: api error InvalidTag). 그래서 ASCII로 고정한다.
  buckets = {
    assets_prod = {
      name    = "${var.assets_prod_bucket_name}${local.bucket_suffix}"
      purpose = "prod artwork images textures 3D assets"
      env     = "prod"
      kind    = "assets"
    }
    assets_dev = {
      name    = "${var.assets_dev_bucket_name}${local.bucket_suffix}"
      purpose = "dev assets - no production data copies"
      env     = "dev"
      kind    = "assets"
    }
    backups = {
      name    = "${var.backups_bucket_name}${local.bucket_suffix}"
      purpose = "postgres dumps / nginx log archive / release artifacts"
      env     = "shared"
      kind    = "backups"
    }
  }

  asset_bucket_keys  = [for k, v in local.buckets : k if v.kind == "assets"]
  backup_bucket_keys = [for k, v in local.buckets : k if v.kind == "backups"]
}

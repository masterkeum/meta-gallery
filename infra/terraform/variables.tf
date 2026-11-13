# 메타 갤러리 인프라 - 입력 변수
#
# 원칙: 자격증명(액세스 키/시크릿/토큰)·계정 ID·비밀번호는 이 파일에도,
#       tfvars 예시 파일에도 **값으로 넣지 않는다.**
#       자격증명은 환경변수(AWS_PROFILE 등)나 AWS CLI 프로파일로만 전달한다.

/* ---------- 공통 ---------- */

variable "aws_region" {
  description = "AWS 리전. 계획서 1-1에서 시드니(ap-southeast-2)로 확정."
  type        = string
  default     = "ap-southeast-2"

  # 허용 리전이 2개뿐인 이유: 이 AWS 계정은 조직(관리계정 <AWS_ORG_MANAGEMENT_ACCOUNT_ID>,
  # <AWS_ORG_ID>)에 속해 있고, 조직 SCP가 ap-northeast-2(서울)·ap-northeast-1(도쿄)
  # ·ap-southeast-1(싱가포르)·us-west-2(오레곤)·eu-west-1(아일랜드)을
  # explicit deny 한다. 2026-11-13 실제 probe 결과 쓸 수 있는 리전은
  # ap-southeast-2(시드니)와 us-east-1(버지니아) 2곳뿐이다.
  # 차단된 리전을 넣으면 apply가 AccessDeniedException(explicit deny in a
  # service control policy)으로 실패한다. 계획서 1-1 고정값은 ap-southeast-2다.
  validation {
    condition     = contains(["ap-southeast-2", "us-east-1"], var.aws_region)
    error_message = "조직 SCP가 허용하는 리전은 ap-southeast-2(시드니)와 us-east-1(버지니아) 2개뿐이다. 계획서 1-1 고정값은 ap-southeast-2이며, 바꾸려면 계획서 1장을 먼저 수정해야 한다."
  }
}

variable "availability_zone" {
  description = "Lightsail 인스턴스 가용영역. 계획서 1-1 고정값(ap-southeast-2a)."
  type        = string
  default     = "ap-southeast-2a"

  # aws_region과 짝이 맞아야 한다. 리전을 us-east-1로 바꾸면 이 값도 us-east-1a 등으로 바꾼다.
  validation {
    condition     = can(regex("^(ap-southeast-2|us-east-1)[a-f]$", var.availability_zone))
    error_message = "가용영역은 허용 리전(ap-southeast-2 / us-east-1) 뒤에 a~f를 붙인 형식이어야 한다. 예: ap-southeast-2a"
  }
}

variable "aws_profile" {
  description = <<-EOT
    사용할 AWS CLI named profile 이름. 비워 두면(null) 표준 자격증명 탐색 순서를 따른다
    (환경변수 → ~/.aws/credentials → 인스턴스 역할). 액세스 키 자체를 여기에 적지 않는다.
  EOT
  type        = string
  default     = null
}

variable "project_name" {
  description = "태그에 쓰는 프로젝트 이름."
  type        = string
  default     = "meta-gallery"
}

variable "extra_tags" {
  description = "모든 자원에 추가로 붙일 태그."
  type        = map(string)
  default     = {}
}

/* ---------- Lightsail ---------- */

variable "instance_name" {
  description = "Lightsail 인스턴스 이름. 계획서 1-1 고정값."
  type        = string
  default     = "meta-gallery-app"
}

variable "blueprint_id" {
  description = "Lightsail blueprint(OS 이미지) ID. 계획서 1-1 고정값."
  type        = string
  default     = "ubuntu_24_04"
}

variable "bundle_id" {
  description = "Lightsail bundle(요금제) ID. 계획서 1-1 고정값(1GB RAM / 40GB SSD / 1TB 전송, 월 $7). 시드니에는 $5 번들이 nano_3_2(0.5GB RAM)뿐이어서 PostgreSQL 구동에 부족해 기각됐다."
  type        = string
  default     = "micro_3_2"
}

variable "static_ip_name" {
  description = "Lightsail 고정 IP 이름. 계획서 1-1 고정값. 인스턴스에 붙어 있는 동안 무료."
  type        = string
  default     = "meta-gallery-ip"
}

variable "ssh_key_pair_name" {
  description = <<-EOT
    인스턴스에 심을 Lightsail 키페어 이름. CEO가 Lightsail 콘솔에서 미리 만들어 둔 키페어 이름을 넣는다.
    null로 두면 Lightsail 리전 기본 키페어가 쓰인다(권장하지 않음 - 개인키 보관 주체가 불명확해진다).
    키 생성·보관 방식은 정보보호본부 애플리케이션보안팀 검토 대상이다(계획서 3-2).
  EOT
  type        = string
  default     = null
}

variable "ssh_allowed_cidrs" {
  description = <<-EOT
    TCP 22(SSH) 접속을 허용할 CIDR 목록. 관리자 접속 IP만 넣는다(예: ["203.0.113.4/32"]).
    전체 공개(0.0.0.0/0)는 validation으로 막아 둔다.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0
    error_message = "SSH 허용 CIDR을 최소 1개 지정해야 한다. 접속 IP를 모르면 적용을 미룬다."
  }

  validation {
    condition = length([
      for c in var.ssh_allowed_cidrs : c
      if c == "0.0.0.0/0" || c == "::/0"
    ]) == 0
    error_message = "22번 포트를 전체 공개할 수 없다. 관리자 접속 IP를 /32로 지정한다."
  }
}

variable "web_allowed_cidrs" {
  description = "TCP 80/443 허용 CIDR. 공개 웹이므로 전체 공개가 기본값이다."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_auto_snapshot" {
  description = "Lightsail 자동 스냅샷(일 1회) 사용 여부. 계획서 1-5에서 켜기로 확정."
  type        = bool
  default     = true
}

variable "auto_snapshot_time_utc" {
  description = <<-EOT
    자동 스냅샷 시각(UTC, HH:00 형식, 정시만 허용). 기본 "19:00" UTC = 04:00 KST.
    계획서 1-5 고정값(2026-11-13 팀장 확정). pg_dump(03:10 KST, 타이머
    RandomizedDelaySec=120까지 더하면 최대 03:12)보다 50분 **뒤**에 돌린다.
      - 디스크 I/O 경합 회피: burst 인스턴스에서 스냅샷과 pg_dump가 겹치지 않게 한다.
      - 스냅샷이 그날 생성된 /var/backups/meta-gallery 로컬 덤프까지 포함한다.
    이 값을 바꾸면 meta-gallery-backup.timer(03:10 KST)와의 간격을 다시 확인한다.
  EOT
  type        = string
  default     = "19:00"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):00$", var.auto_snapshot_time_utc))
    error_message = "HH:00 형식(정시)이어야 한다. 예: 18:00"
  }
}

/* ---------- S3 ---------- */

# S3 버킷 이름은 **전역에서 유일**한 식별자라 외부에서 존재 여부를 열거할 수 있다.
# 그래서 공개 저장소에는 기본값을 두지 않고, terraform.tfvars(미추적)로 주입한다.
# 이름 규칙은 docs/infra/aws-resources.md 2장에 있다.

variable "assets_prod_bucket_name" {
  description = "운영계 에셋 버킷 이름. 전역 유일값이라 기본값을 두지 않는다(tfvars로 주입)."
  type        = string
}

variable "assets_dev_bucket_name" {
  description = "개발계 에셋 버킷 이름. 전역 유일값이라 기본값을 두지 않는다. 운영 데이터 복사 금지."
  type        = string
}

variable "backups_bucket_name" {
  description = "백업·릴리스 artifact 버킷 이름. 전역 유일값이라 기본값을 두지 않는다."
  type        = string
}

variable "bucket_name_suffix" {
  description = <<-EOT
    버킷 이름 충돌(전역 유일 제약) 대비 접미사. 기본은 빈 문자열(접미사 없음).
    계획서 1-4 대체 규칙: 위 이름이 선점돼 있으면 "-2"를 붙이지 말고
    **AWS 계정 ID 뒤 4자리**를 접미사로 쓴다. 예: bucket_name_suffix = "<ACCOUNT_ID_LAST4>"
    → <ASSETS_BUCKET_PROD>-<ACCOUNT_ID_LAST4>
    적용 후 `terraform output bucket_name_suffix_hint`로 계정 ID 뒤 4자리를 확인할 수 있다.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.bucket_name_suffix == "" || can(regex("^[a-z0-9]{1,16}$", var.bucket_name_suffix))
    error_message = "접미사는 비워 두거나 소문자·숫자 1~16자여야 한다(S3 버킷 이름 규칙)."
  }
}

variable "asset_noncurrent_version_expiration_days" {
  description = "에셋 버킷: 이전 버전 보관 일수. 계획서 1-4 고정값 30일."
  type        = number
  default     = 30
}

variable "backup_glacier_ir_transition_days" {
  description = "백업 버킷: Glacier Instant Retrieval 전환 일수. 계획서 1-4 고정값 30일."
  type        = number
  default     = 30
}

variable "backup_expiration_days" {
  description = "백업 버킷: 삭제 일수. 계획서 1-4 고정값 180일."
  type        = number
  default     = 180
}

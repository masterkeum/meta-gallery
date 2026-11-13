# infra/terraform — 메타 갤러리 AWS 자원 코드

작성: IT본부 인프라팀 (2026-11-13)
근거: `docs/plans/2026-11-13-aws-infra.md` 1-1 / 1-4 / 1-5, 2장 항목 2
자원 설명: `docs/infra/aws-resources.md`

## 이 코드가 만드는 것

| 파일 | 내용 |
|---|---|
| `versions.tf` | Terraform ≥ 1.6, AWS 프로바이더 `~> 6.0`, 백엔드(주석 처리된 S3 전환안) |
| `main.tf` | 프로바이더 설정, 공통 태그, 버킷 이름 조립 로컬값 |
| `variables.tf` | 모든 입력 변수(이름·리전·CIDR·수명주기 일수) |
| `lightsail.tf` | 인스턴스 `meta-gallery-app`, 고정 IP `meta-gallery-ip`, 방화벽 80/443/22 |
| `s3.tf` | 버킷 3개 + 퍼블릭 차단·ACL 비활성·버전관리·SSE-S3·TLS 강제·수명주기 |
| `outputs.tf` | 고정 IP, SSH 명령, 버킷 이름/ARN, 열린 포트 요약 |
| `terraform.tfvars.example` | 변수 값 예시(자리표시자만) |

**만들지 않는 것**: 인스턴스 내부 구성(`infra/server/`), DuckDNS·인증서(`infra/duckdns/`, `scripts/ops/`), GitHub Actions(`.github/`). 각각 다른 담당 산출물이다.

## 현재 상태 — 아직 적용하지 않았다

> **이 코드는 한 번도 `init`/`plan`/`apply`되지 않았다.**
> AWS 자격증명이 없어(`NoCredentials`) 프로바이더를 내려받을 수 없고,
> 실제 자원을 만들면 그 시점부터 과금이 시작된다.
> 지금까지 실행한 검사는 `terraform fmt -check`(서식) 하나뿐이다.
> **문법 검증(`terraform validate`)과 계획 확인(`terraform plan`)은 확인하지 못했다.**
> 아래 "적용 순서"의 1~4단계에서 CEO 승인 후 처음으로 검증된다.

## 적용 전 전제 (2026-11-13 CEO 결정 / 실제 조회 결과)

| 항목 | 값 |
|---|---|
| AWS 계정 | `<AWS_ACCOUNT_ID>` — 다른 사내 프로젝트와 **공유하는 계정**이다(청구서·권한 범위가 함께 묶인다) |
| 계정 플랜 | `accountPlanType: FREE` (AWS 무료 플랜 크레딧). 잔액·만료일은 경영 정보라 공개본에 적지 않는다 |
| 조직 | 관리계정 `<AWS_ORG_MANAGEMENT_ACCOUNT_ID>` / 조직 `<AWS_ORG_ID>`의 멤버 계정 |
| **조직 SCP 제약** | SCP가 `ap-northeast-2`(서울)·`ap-northeast-1`(도쿄)·`ap-southeast-1`(싱가포르)·`us-west-2`·`eu-west-1`을 **explicit deny** 한다. 쓸 수 있는 리전은 **`ap-southeast-2`(시드니)** 와 **`us-east-1`(버지니아)** 2곳뿐이다 |
| 선택한 리전 | `ap-southeast-2` / AZ `ap-southeast-2a` — `variables.tf`의 validation이 이 2개 리전만 통과시킨다 |
| 선택한 번들 | `micro_3_2` ($7, 1GB RAM / 40GB SSD / **1TB 전송**). 시드니의 $5 번들은 `nano_3_2`(0.5GB RAM)뿐이라 PostgreSQL에 부족해 기각 |

차단된 리전으로 적용하면 다음처럼 실패한다(실제 오류 문구):

```
AccessDeniedException ... not authorized to perform: lightsail:GetInstances
on resource: arn:aws:lightsail:ap-northeast-2:<AWS_ACCOUNT_ID>:*
with an explicit deny in a service control policy
```

- **한국에서 시드니까지 지연은 약 130~150ms**다. 정적 에셋 1회 로드 위주인 현 목업에는 감수 가능하지만, 실시간 멀티플레이·채팅을 넣으면 재검토가 필요하다.
- 무료 플랜 크레딧이 **만료되면** 유료 플랜 전환 또는 자원 중단 결정이 필요하다.

## 적용 전 준비물 (CEO 작업)

1. **AWS 계정과 자격증명** — 위 계정(`<AWS_ACCOUNT_ID>`)의 IAM 사용자 또는 SSO 프로파일. 최소 권한은 Lightsail 전체 + S3 버킷 생성/정책 설정 + `sts:GetCallerIdentity`.
   ```bash
   export AWS_PROFILE=meta-gallery      # 또는 aws configure --profile meta-gallery
   aws sts get-caller-identity          # 계정이 보이면 준비 완료
   ```
   액세스 키를 `.tf`/`.tfvars` 파일에 적지 않는다.
2. **SSH 키페어** — Lightsail 콘솔(시드니 리전, ap-southeast-2)에서 키페어를 만들고 개인키를 안전한 곳에 보관한 뒤, 그 이름을 `ssh_key_pair_name`에 넣는다. 보관 방식은 정보보호본부 애플리케이션보안팀 검토 대상이다.
3. **22번 포트용 접속 IP** — `curl -s https://checkip.amazonaws.com`으로 확인한 값을 `/32`로 `ssh_allowed_cidrs`에 넣는다. 전체 공개(`0.0.0.0/0`)는 코드에서 막아 두었다.

## 적용 순서

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars          # <> 자리표시자 채우기

# 1. 프로바이더 내려받기 (여기서 처음 네트워크를 쓴다)
terraform init

# 2. 문법·스키마 검증 (아직 AWS를 호출하지 않는다)
terraform fmt -check
terraform validate

# 3. 무엇이 만들어지는지 확인 — 읽기 전용, 과금 없음
terraform plan -out=tfplan
#    기대: 생성 약 20개 / 변경 0 / 삭제 0
#    확인할 것: 버킷 이름 3개, 인스턴스 bundle=micro_3_2, 포트 목록에 5432 없음

# 4. 적용 (여기서부터 과금 시작)
terraform apply tfplan

# 5. 결과 확인
terraform output
terraform output static_ip_address        # DuckDNS에 등록할 IP
terraform output open_inbound_ports       # 5432가 없어야 한다
```

### 버킷 이름이 선점돼 있을 때

`BucketAlreadyExists` 오류가 나면 이름을 임의로 바꾸지 않고 계획서 1-4의 대체 규칙을 따른다. `-2`를 붙이지 않고 **계정 ID 뒤 4자리**를 접미사로 쓴다.

```bash
aws sts get-caller-identity --query Account --output text | tail -c 5
# 또는 적용이 일부라도 끝났다면: terraform output bucket_name_suffix_hint
```

얻은 4자리를 `terraform.tfvars`에 넣고 다시 plan/apply 한다.

```hcl
bucket_name_suffix = "<ACCOUNT_ID_LAST4>"   # → <ASSETS_BUCKET_PROD>-<ACCOUNT_ID_LAST4>
```

접미사를 바꾸면 **버킷은 이름이 바뀌어 새로 만들어지고 기존 버킷은 삭제 대상이 된다.** 적용 전 `plan` 출력에서 `destroy`가 없는지 반드시 확인한다.

### 적용 후 이어지는 작업

1. 고정 IP를 DuckDNS 두 서브도메인에 등록 → `infra/duckdns/`
2. 인스턴스에 SSH로 접속해 프로비저닝 실행 → `infra/server/scripts/provision.sh`
3. 인증서 발급(staging dry-run 먼저) → `scripts/ops/issue-certificates.sh`
4. GitHub Secrets에 호스트·키 등록 → `docs/infra/git-and-cicd.md`

## state 파일 다루기

- 지금은 **로컬 state**다(`terraform.tfstate`). state를 보관할 S3 버킷을 이 코드가 직접 만들기 때문에(닭-달걀) 1단계에서 원격 백엔드를 쓸 수 없다.
- state에는 자원 속성이 그대로 들어간다. **저장소에 커밋하지 않는다.** 루트 `.gitignore`에 `*.tfstate*`, `.terraform/`가 들어가 있어야 한다(팀원 1 담당).
- 로컬 state는 PC가 고장나면 사라진다. 적용 직후 `terraform.tfstate`를 별도 안전한 곳에 복사해 두길 권한다.

### state를 S3로 옮기기 (apply 이후 선택)

1. state 전용 버킷을 따로 만든다(에셋·백업 버킷과 섞지 않는다). 예: `<프로젝트>-tfstate-<리전약칭>`. 버전 관리 ON, 퍼블릭 차단 4/4 ON, SSE-S3.
2. `versions.tf`의 `backend "s3"` 블록 주석을 풀고 `bucket`·`key`·`region`을 채운다.
3. `terraform init -migrate-state` 를 실행한다. 로컬 state를 S3로 옮길지 물으면 `yes`.
4. 옮겨진 뒤 `terraform plan`이 "No changes"로 나오는지 확인한다. 로컬 `terraform.tfstate`는 바로 지우지 말고 백업으로 남겨 둔다.
5. 잠금은 `use_lockfile = true`(S3 조건부 쓰기)를 쓴다. DynamoDB 테이블은 추가 비용이 붙어 권하지 않는다.

## ⚠️ `terraform destroy` 주의

`terraform destroy`는 **운영 자원을 되돌릴 수 없게 지운다.** 인프라팀은 이 명령을 실행하지 않으며, 실행은 CEO 결정 사항이다.

이 디렉터리에서 destroy가 지우는 것:

- **Lightsail 인스턴스** — 디스크(40GB)와 그 안의 PostgreSQL 데이터, nginx 설정, Let's Encrypt 인증서가 **전부 사라진다.** 자동 스냅샷도 인스턴스 삭제 시 함께 정리될 수 있다.
- **고정 IP** — 반납되면 같은 IP를 다시 받을 수 없다. DuckDNS 레코드와 발급받은 인증서를 모두 다시 맞춰야 한다.
- **S3 버킷 3개** — `force_destroy = false`로 두었으므로 **객체가 남아 있으면 destroy는 실패한다.** 이것은 사고 방지 장치다. 실패했다고 `force_destroy = true`로 바꾸지 않는다. 정말 지워야 한다면 백업을 다른 곳에 내려받은 사실을 먼저 확인받는다.

안전한 사용법:

```bash
# 전체 destroy 전에는 반드시 무엇이 지워지는지 먼저 본다
terraform plan -destroy

# 특정 자원만 지울 때 (예: 잘못 만든 방화벽 규칙만)
terraform destroy -target=aws_lightsail_instance_public_ports.app
```

`-auto-approve`는 쓰지 않는다. 지우기 전에 Lightsail 수동 스냅샷을 하나 만들어 두고, `pg_dump` 백업이 S3에 올라가 있는지 확인한다.

## 비용

월 약 **$7.6~8.2** (비공개 운영 기준)로 가정했다. 이는 **인프라팀 가정이며 경영지원본부 재무팀 검증 대기 중**이다. 현재는 AWS 무료 플랜 크레딧에서 차감되므로 크레딧 만료일까지 실지출은 $0이다. 근거 표는 `docs/infra/aws-resources.md`와 계획서 3-3에 있다.

## 보안 검토 대기

SSH 키 보관, 22번 포트 허용 범위, S3 공개 범위(1단계 완전 비공개 권고), state 파일 취급은 정보보호본부 애플리케이션보안팀 검토 대상이다(계획서 3-2). 검토 전 적용하지 않는다.

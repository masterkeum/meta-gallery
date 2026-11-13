# AWS 자원 목록과 설정 근거 (Lightsail · 고정 IP · 방화벽 · S3)

- 날짜: 2026-11-13
- 작성 주체: 주관 IT본부 인프라팀
- 근거 계획: `docs/plans/2026-11-13-aws-infra.md` (1-1, 1-4, 1-5, 2장 항목 2)
- 대응 코드: `infra/terraform/`

> **상태: 설계·코드만 완료. 실제 자원은 하나도 만들지 않았다.**
> `terraform init`/`validate`/`plan`을 실행하지 않았다(적용은 CEO 승인 아래 비서실장이 직접 한다).
> 이 문서의 자원은 CEO 승인 후 `infra/terraform/README.md`의 적용 순서를 따를 때 처음 생성된다.

## 0. 적용 전 전제 (2026-11-13 계정 조회 결과 + CEO 결정)

적용은 아래 전제 위에서만 성립한다. 전제가 바뀌면 리전·번들·비용을 다시 계산해야 한다.

| 전제 | 값 | 영향 |
|---|---|---|
| AWS 계정 | **`<AWS_ACCOUNT_ID>`** (다른 사내 프로젝트 계정 재사용) | 청구서와 IAM 권한 범위가 다른 프로젝트와 **공유**된다. 자원 태그(`Project=meta-gallery`)로 구분한다 |
| 계정 플랜 | `accountPlanType: FREE` (AWS 무료 플랜) | 12개월 무료 티어가 아니라 **크레딧 소진형**이다 |
| 남은 크레딧 | **`<크레딧 잔액>`** (경영 정보, 공개본에서 제외) | 월 $7.6~8.2가 여기서 차감된다 → 실지출 $0 |
| 플랜 만료 | **`<만료일>`** (경영 정보, 공개본에서 제외) | 만료 후 유료 플랜 전환 또는 자원 중단 결정이 필요하다(CEO) |
| 조직 | 관리계정 `<AWS_ORG_MANAGEMENT_ACCOUNT_ID>` / 조직 `<AWS_ORG_ID>`의 멤버 계정 | SCP를 이 계정에서 바꿀 수 없다 |
| **조직 SCP 리전 차단** | `ap-northeast-2`(서울)·`ap-northeast-1`(도쿄)·`ap-southeast-1`(싱가포르)·`us-west-2`·`eu-west-1` = **explicit deny** / **`ap-southeast-2`(시드니)·`us-east-1`(버지니아) = 허용** | 서울을 쓸 수 없다. 설계 전체를 시드니로 옮겼다 |

차단 리전으로 호출하면 다음처럼 실패한다(2026-11-13 실제 오류):

```
AccessDeniedException ... not authorized to perform: lightsail:GetInstances
on resource: arn:aws:lightsail:ap-northeast-2:<AWS_ACCOUNT_ID>:*
with an explicit deny in a service control policy
```

번들 조회 결과(시드니):

| 번들 | 가격 | RAM | 디스크 | 전송 | 판정 |
|---|---|---|---|---|---|
| `nano_3_2` | $5 | 0.5GB | 20GB | 512GB | **기각** — PostgreSQL 구동에 0.5GB RAM이 부족 |
| **`micro_3_2`** | **$7** | **1GB** | **40GB** | **1TB** | **채택** (CEO 결정) |

- 계획서의 `nano_3_0`(1GB/40GB/2TB @ $5)은 **시드니에 존재하지 않는다.**
- **한국↔시드니 지연은 약 130~150ms**다. 정적 에셋 1회 로드 위주인 현 목업에는 감수 가능하지만, 실시간 멀티플레이·채팅을 넣으면 리전·아키텍처를 재검토해야 한다.
- EC2 `t3.micro` 무료티어 전환안, 조직에 서울 SCP 예외를 요청하는 안은 2026-11-13 CEO 결정으로 **모두 기각**됐다.
- 근거 문서: `docs/decisions/2026-11-13-aws-infra.md`

## 1. 자원 한눈에 보기

| # | 자원 | Terraform 주소 | 이름 | 과금 |
|---|---|---|---|---|
| 1 | Lightsail 인스턴스 | `aws_lightsail_instance.app` | `meta-gallery-app` | 월 $7 (micro_3_2) |
| 2 | 고정 IP | `aws_lightsail_static_ip.app` | `meta-gallery-ip` | 인스턴스에 연결 중이면 $0 |
| 3 | 고정 IP 연결 | `aws_lightsail_static_ip_attachment.app` | — | $0 |
| 4 | 인바운드 방화벽 | `aws_lightsail_instance_public_ports.app` | — | $0 |
| 5 | 자동 스냅샷(애드온) | `aws_lightsail_instance.app` 내 `add_on` | 일 1회 19:00 UTC | 사용 용량 기준 |
| 6 | S3 버킷 (운영 에셋) | `aws_s3_bucket.this["assets_prod"]` | `<ASSETS_BUCKET_PROD>` | 용량·요청 기준 |
| 7 | S3 버킷 (개발 에셋) | `aws_s3_bucket.this["assets_dev"]` | `<ASSETS_BUCKET_DEV>` | 동일 |
| 8 | S3 버킷 (백업) | `aws_s3_bucket.this["backups"]` | `<BACKUPS_BUCKET>` | 동일 |
| 9 | 버킷별 부속 설정 | 퍼블릭 차단 / ACL 비활성 / 버전관리 / 암호화 / 정책 / 수명주기 | 버킷마다 5~6개 | $0 |

리전은 전부 **`ap-southeast-2`(시드니)**, 가용영역은 **`ap-southeast-2a`**다. 서울이 아닌 이유는 0장(적용 전 전제)의 조직 SCP 제약 때문이다.

## 2. Lightsail 인스턴스 `meta-gallery-app`

### 무엇인가
운영계와 개발계를 한 대에 올리는 Ubuntu 24.04 서버다. nginx가 정적 파일(`dist/meta-gallery.html`)을 서비스하고, 같은 인스턴스 안에 PostgreSQL 16이 localhost로만 뜬다. 향후 백엔드 API도 이 인스턴스의 루프백 포트(prod 3000 / dev 3001)에 붙는다.

### 왜 이 설정인가

| 설정 | 값 | 이유 |
|---|---|---|
| 서비스 선택 | EC2가 아니라 Lightsail | 요금이 월 고정이라 예측 가능하고, 전송량 1TB가 포함돼 있다. EC2+EIP+전송량 조합은 같은 사양에서 요금 변동이 크다. (EC2 `t3.micro` 무료티어안은 Terraform을 EC2+VPC+보안그룹+EIP로 재작성해야 해서 2026-11-13 CEO 결정으로 기각됐다.) |
| blueprint | `ubuntu_24_04` | LTS로 2029년까지 보안 업데이트. 기본 저장소에 PostgreSQL 16이 있어 외부 저장소(PGDG) 추가가 필요 없다. |
| bundle | `micro_3_2` | 시드니에서 쓸 수 있는 최소 사양이다. $5 번들은 `nano_3_2`(0.5GB RAM / 20GB / 512GB 전송)뿐인데 PostgreSQL 구동에 0.5GB RAM이 부족해 기각됐다(2026-11-13 CEO 결정). $7은 무료 플랜 크레딧에서 차감된다. |
| 가용영역 | `ap-southeast-2a` | 1대 구성이라 AZ 분산 의미가 없고, 고정해 두면 재생성 시 동일 조건이 보장된다. |
| 리전 | `ap-southeast-2`(시드니) | 조직 SCP가 서울·도쿄·싱가포르를 explicit deny 한다. 허용 리전은 시드니와 버지니아뿐이고, 둘 중 한국에서 가까운 쪽이 시드니다(0장). |
| IP 유형 | `ipv4` (dualstack 아님) | IPv6까지 열면 방화벽 CIDR을 양쪽으로 관리해야 한다. 필요해지면 올린다. |
| `user_data` | 비움 | 내부 구성은 `infra/server/scripts/provision.sh`를 SSH로 실행한다. user_data는 실패 시 로그 추적과 재실행이 어렵다. |
| 자동 스냅샷 | 일 1회 19:00 UTC (= 04:00 KST) | 인스턴스 전체를 보호하는 마지막 안전망. `pg_dump`(03:10 KST)보다 **50분 뒤**에 돌린다(2026-11-13 팀장 확정, 계획서 1-5). burst 인스턴스에서 디스크 I/O가 겹치지 않게 하고, 스냅샷이 그날 로컬 덤프까지 포함하게 하려는 것이다. |

### 알려진 제약 (리스크)
- **1GB RAM**에 PostgreSQL + 향후 Node 2개는 빡빡하다. swap 2GB(`infra/server/`)와 메모리 감시로 버티고, 한계가 보이면 bundle 상향을 CEO에게 올린다.
- **인스턴스 1대 공유**라 개발계 부하·장애가 운영계에 번질 수 있다.
- bundle 변경은 Lightsail에서 in-place 업그레이드가 아니라 **스냅샷 → 새 인스턴스 생성** 경로다. 고정 IP를 옮기면 다운타임은 짧지만 무중단은 아니다.

## 3. 고정 IP `meta-gallery-ip`

- DuckDNS 두 서브도메인(`metagallery.duckdns.org`, `metagallery-dev.duckdns.org`)이 같은 IP를 가리키고, 분기는 nginx `server_name`이 한다.
- **인스턴스에 연결돼 있는 동안만 무료**다. 인스턴스를 지우고 고정 IP만 남겨 두면 과금된다.
- 한 번 반납하면 같은 IP를 다시 받을 수 없다. IP가 바뀌면 DuckDNS 레코드와 인증서를 다시 맞춰야 한다.

## 4. 방화벽 (인바운드)

| 포트 | 허용 범위 | 용도 |
|---|---|---|
| TCP 80 | `0.0.0.0/0` | HTTP → HTTPS 리다이렉트, Let's Encrypt HTTP-01 챌린지 |
| TCP 443 | `0.0.0.0/0` | HTTPS |
| TCP 22 | `ssh_allowed_cidrs` (관리자 접속 IP `/32`) | 운영 접속·배포 |

### 왜 이렇게 좁혔나
- **TCP 5432(PostgreSQL)는 절대 열지 않는다.** DB는 `listen_addresses = 'localhost'`로만 뜬다. 공개 DB 포트는 가장 흔한 침해 경로다.
- **3000/3001(백엔드)도 열지 않는다.** nginx가 루프백으로 프록시한다.
- **22번 전체 공개는 코드에서 차단**했다. `ssh_allowed_cidrs`에 `0.0.0.0/0`을 넣으면 변수 validation이 적용을 거부한다.
- `aws_lightsail_instance_public_ports`는 포트 규칙 **전체를 대체**한다. 즉 Lightsail 기본 규칙(ICMP 등)도 함께 닫힌다. ping이 필요하면 별도 요청으로 추가한다.

### 운영 시 주의
CEO 공인 IP가 바뀌면(통신사 재할당, 다른 장소 접속) **SSH가 막힌다.** 이때는 Lightsail 콘솔의 브라우저 SSH로 들어가거나, `ssh_allowed_cidrs`를 고쳐 다시 apply한다. 22번 포트 허용 범위는 정보보호본부 애플리케이션보안팀 검토 대상이다.

## 5. S3 버킷 3개

### 용도

| 버킷 | 용도 | 공개 범위 |
|---|---|---|
| `<ASSETS_BUCKET_PROD>` | 운영계 작품 이미지·텍스처·3D 에셋 | 완전 비공개 |
| `<ASSETS_BUCKET_DEV>` | 개발계 에셋 (**운영 데이터 복사 금지**) | 완전 비공개 |
| `<BACKUPS_BUCKET>` | PostgreSQL `pg_dump`, nginx 로그 아카이브, 릴리스 artifact | 완전 비공개 |

백업 업로드 경로: `s3://<BACKUPS_BUCKET>/postgres/<env>/YYYY/MM/DD/`

### 세 버킷 공통 보안 설정

| 설정 | 값 | 이유 |
|---|---|---|
| Block Public Access | 4항목 **전부 ON** (`block_public_acls`, `block_public_policy`, `ignore_public_acls`, `restrict_public_buckets`) | 실수로 공개 정책·ACL을 붙여도 계정/버킷 차원에서 막힌다. S3 사고의 대부분이 이 설정 누락이다. |
| ACL | `BucketOwnerEnforced` (ACL 비활성) | ACL은 권한 경로가 하나 더 늘어나는 레거시 기능이다. 정책 하나로만 권한을 관리한다. |
| 버전 관리 | ON | 덮어쓰기·실수 삭제 복구. 백업 버킷에서는 랜섬웨어성 덮어쓰기 방어도 된다. |
| 기본 암호화 | SSE-S3 (`AES256`) | 저장 시 암호화를 기본값으로 둔다. SSE-KMS는 키 요금과 요청당 과금이 붙어 최소 비용 기조(월 $7급 인스턴스 1대)에 맞지 않는다. 규제 요건이 생기면 정보보호팀과 재검토한다. |
| TLS 강제 | `aws:SecureTransport = false` 이면 `s3:*` **Deny** | 평문 HTTP로 올라오는 백업·에셋을 원천 차단한다. 버킷 정책에 명시적으로 넣었다. |
| `force_destroy` | `false` | 객체가 남아 있으면 `terraform destroy`가 실패한다. 의도한 사고 방지 장치다. |

### 수명주기

| 버킷 | 규칙 |
|---|---|
| 에셋 (운영·개발) | 이전 버전 **30일 후 삭제**. 현재 버전은 유지. 미완료 멀티파트 업로드 7일 후 정리. |
| 백업 | **30일 후 Glacier Instant Retrieval** 전환 → **180일 후 삭제**. 이전 버전 30일 후 삭제. 미완료 멀티파트 7일 후 정리. |

Glacier Deep Archive가 아니라 Instant Retrieval을 고른 이유: 복구는 급할 때 하는 일인데 Deep Archive는 꺼내는 데 수 시간이 걸린다. IR은 즉시 꺼낼 수 있으면서 Standard보다 싸다. 다만 **최소 보관 기간 90일**이 있으므로, 30일 전환 후 180일 삭제 설정이면 전환된 객체는 최소 기간을 넘겨서 삭제된다(조기 삭제 수수료 없음).

### 버킷 이름 충돌 대비 (대체 규칙)

S3 버킷 이름은 **전역에서 유일**해야 하므로 위 이름이 이미 선점돼 있을 수 있다. 그때는 이름을 임의로 바꾸지 않고 이 규칙을 따른다.

- `-2`를 붙이지 **않는다.**
- **AWS 계정 ID 뒤 4자리**를 접미사로 쓴다 → `<ASSETS_BUCKET_PROD>-<ACCOUNT_ID_LAST4>`
- 코드에서는 `bucket_name_suffix` 변수 한 개만 바꾸면 세 버킷에 함께 적용된다.
- 계정 ID 뒤 4자리는 `terraform output bucket_name_suffix_hint` 또는 `aws sts get-caller-identity --query Account --output text | tail -c 5`로 확인한다.
- 접미사를 바꾸면 버킷은 **새로 만들어지고 기존 버킷은 삭제 대상**이 된다. apply 전 `plan` 출력에서 `destroy`가 없는지 확인한다.

### 공개가 필요해지면 (CEO 결정 대기)

1단계는 **세 버킷 모두 완전 비공개**다. 현재 작품 이미지는 `gallery-mockup.html` 안에서 캔버스로 그려지므로 공개 버킷이 필요 없다.

에셋을 외부에 공개 전달해야 할 상황이 오면, **버킷을 공개로 열지 않고 CloudFront + OAC(Origin Access Control)** 를 앞에 둔다. 이유:

- 버킷은 계속 비공개로 남고, CloudFront만 서명된 요청으로 원본에 접근한다.
- 캐시가 끼므로 S3 요청 수와 데이터 전송 비용이 줄어든다.
- 공개 범위를 끊을 때 버킷 정책을 건드리지 않고 배포만 비활성화하면 된다.

**이 방향은 인프라팀 권고이며 최종 선택은 CEO 결정 사항이다**(계획서 5장 1번). 전환 시 검토 항목은 정보보호본부 애플리케이션보안팀 검토 대상이다(계획서 3-2).

## 6. 적용 전 CEO가 준비해야 할 것

| # | 준비물 | 어떻게 | 인프라팀이 대신 못 하는 이유 |
|---|---|---|---|
| 1 | **AWS 자격증명** | IAM 사용자 또는 SSO 프로파일을 만들고 로컬에 `AWS_PROFILE`로 설정. `aws sts get-caller-identity`가 성공해야 한다. | 계정 생성·결제 수단 등록은 CEO 권한이다. 인프라팀은 외부 서비스 가입·결제를 하지 않는다. |
| 2 | **22번 포트용 접속 IP** | `curl -s https://checkip.amazonaws.com` 결과를 `/32`로 `ssh_allowed_cidrs`에 입력. | CEO의 접속 위치·공인 IP를 인프라팀이 알 수 없다. |
| 3 | **SSH 키페어 이름** | Lightsail 콘솔(시드니 리전, `ap-southeast-2`)에서 키페어 생성 → 개인키를 안전한 곳에 보관 → 키페어 **이름**만 `ssh_key_pair_name`에 입력. | 개인키 보관 주체는 한 명이어야 한다. 키 생성·보관 방식은 정보보호팀 검토 대상이다. |

필요 최소 권한(참고): Lightsail 전체, S3 버킷 생성·정책·암호화·수명주기 설정, `sts:GetCallerIdentity`. 범위 축소안은 정보보호팀 검토 대상이다.

## 7. 월 예상 비용 — **재무팀 검증 대기 중**

아래는 **인프라팀 가정**이며 경영지원본부 **재무팀 검증이 필요하다.** 실제 청구액은 환율·사용량·세금에 따라 달라진다.

| 항목 | 가정 | 월 추정 |
|---|---|---|
| Lightsail `micro_3_2` (시드니) | 1GB RAM / 40GB SSD / 1TB 전송 | $7.00 |
| 고정 IP | 인스턴스에 연결된 동안 무료 | $0 |
| Lightsail 자동 스냅샷 | 약 $0.05/GB·월, 사용 용량 10~20GB 가정 | $0.50~1.00 |
| S3 저장 | Standard 약 $0.025/GB·월, 1GB 미만 가정 | $0.03 미만 |
| S3 요청 | PUT 약 $0.0045/1,000건, GET 약 $0.00035/1,000건, 저빈도 가정 | $0.10 미만 |
| S3 데이터 전송(아웃) | 약 $0.126/GB. 비공개 유지 시 거의 0, 공개 전달 시 급증 가능 | $0~ |
| DuckDNS / Let's Encrypt | 무료 | $0 |
| **합계** | 비공개 운영 기준 | **약 $7.6~8.2** |
| (실지출) | AWS 무료 플랜 크레딧에서 차감(잔액·만료일은 비공개) | **$0** |

비용이 튈 수 있는 지점:
- **S3 데이터 전송(아웃)** — 버킷을 공개로 열거나 CloudFront를 붙이면 전송량에 비례해 늘어난다.
- **Lightsail 전송량 1TB 초과** — `micro_3_2`에 포함된 월 전송량은 1TB다(2TB가 아니다). 초과분은 별도 과금이다. 전송량 80% 알람을 계획에 넣어 두었다(계획서 1-7).
- **스냅샷 용량** — 디스크 사용량이 늘면 비례해 증가한다.

## 8. 확인하지 못한 것

- `terraform init` / `validate` / `plan`을 실행하지 않았다(인프라팀 작업 범위 밖이며, 적용은 CEO 승인 아래 비서실장이 한다). **코드의 리소스 인자 이름과 스키마 적합성은 확인하지 못했다.** 검사한 것은 `terraform fmt -check`(서식)뿐이다.
- 버킷 이름 3개가 전역에서 실제로 사용 가능한지(선점 여부) 확인하지 못했다. AWS API 호출이 필요하다.
- `micro_3_2` 번들의 **vCPU 개수**는 확인하지 못했다. 2026-11-13 번들 조회 결과에 가격·RAM·디스크·전송량만 있었다. 이 문서에서 vCPU 수를 단정하지 않는다.
- 시드니 리전의 `ubuntu_24_04` blueprint 제공 여부는 확인하지 못했다(번들은 조회로 확인됨). `aws lightsail get-blueprints --region ap-southeast-2` 호출이 필요하다.
- 월 비용 단가가 현재 요금표와 일치하는지 확인하지 못했다(재무팀 검증 대기).

## 변경 이력
- 2026-11-13: 최초 작성 (IT본부 인프라팀, 계획서 2장 항목 2)
- 2026-11-13: CEO 결정에 따라 리전·번들 고정값 교체 — 리전 `ap-northeast-2`(서울) → `ap-southeast-2`(시드니), AZ `ap-southeast-2a`, 번들 `nano_3_0` → `micro_3_2`($7 / 1GB / 40GB / 1TB), 버킷 접미사를 새 리전 약칭으로 교체. 0장 "적용 전 전제"(계정·무료 플랜·크레딧·조직 SCP) 추가, 월 비용 $5.6~6.2 → $7.6~8.2(크레딧 차감으로 실지출 $0)로 수정. 근거: `docs/decisions/2026-11-13-aws-infra.md`
- 2026-11-13: CEO 발급값에 맞춰 DuckDNS 호스트명 교체 — 하이픈 있는 옛 이름(`meta-gallery` / `meta-gallery-dev` + `.duckdns.org`)에서 `metagallery.duckdns.org` / `metagallery-dev.duckdns.org`로, DuckDNS 서브도메인 이름도 `metagallery` / `metagallery-dev`로 바꿨다. 인스턴스·고정 IP 이름, S3 버킷, 서버 경로, systemd 유닛, nginx 설정 파일명, certbot `--cert-name`, DB·롤 이름은 바꾸지 않았다. 근거: `docs/plans/2026-11-13-aws-infra.md` 1-3 변경 사유.

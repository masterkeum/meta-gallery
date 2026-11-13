# 모니터링 계획 (Lightsail 기본 지표 + 인스턴스 자체 점검)

- 날짜: 2026-11-13
- 작성 주체: 주관 IT본부 인프라팀(팀원 4) / 협조 요청: 인프라팀 팀원3(logrotate), 경영지원본부 재무팀(비용), 정보보호본부 애플리케이션보안팀(알람 수신처)
- 근거 계획: `docs/plans/2026-11-13-aws-infra.md` 1-7
- 상태: **계획과 스크립트까지만.** AWS 자격증명이 없어 알람을 실제로 만들지 않았다.

## 1. 두 층으로 나눈 이유

| 층 | 수단 | 보는 것 | 한계 |
|---|---|---|---|
| 1. 인스턴스 밖 | Lightsail 기본 지표 알람 | CPU, burst 잔량, 네트워크 전송량, 인스턴스 상태 | **디스크·메모리 지표가 없다.** 앱이 죽어도 모른다 |
| 2. 인스턴스 안 | `scripts/ops/healthcheck.sh` (5분 주기) | 디스크, 메모리/swap, PostgreSQL, `/healthz`, 인증서 만료, 타이머, 백업 최신성 | 인스턴스가 멈추면 같이 멈춘다(그건 1층이 잡는다) |

1층은 "서버가 살아 있나", 2층은 "서비스가 제대로 돌고 있나"를 본다. 둘 중 하나만으로는 구멍이 남는다.

## 2. 1층 — Lightsail 기본 지표 알람 (4개)

`micro_3_2` 번들(1GB RAM / 40GB SSD / **월 전송량 1TB**, 시드니 `ap-southeast-2`) 기준 임계값이다. 알람 수신처(이메일/SMS)는 **CEO 결정 대기**라서 아래 명령의
`--contact-protocols`는 주석으로 남겼다.

| # | 알람 이름 | 지표 | 조건 | 왜 |
|---|---|---|---|---|
| 1 | `meta-gallery-app-cpu-high` | `CPUUtilization` | 2회 연속 5분 평균 ≥ 80% | burst 소진 전 조기 경보 |
| 2 | `meta-gallery-app-burst-low` | `BurstCapacityPercentage` | 2회 연속 ≤ 20% | burst가 바닥나면 CPU가 기준 성능으로 묶여 응답이 느려진다 |
| 3 | `meta-gallery-app-netout-high` | `NetworkOut` | 월 **1TB**의 80% 추세 도달 | 초과분은 종량 과금이다(재무 영향). `micro_3_2`의 포함 전송량은 1TB다 |
| 4 | `meta-gallery-app-status-failed` | `StatusCheckFailed` | 1회 ≥ 1 | 인스턴스 자체 장애 |

### 2-1. 적용 명령 (CEO 승인 + 자격증명 설정 후 실행)

```bash
# 알람 1: CPU 사용률
aws lightsail put-alarm \
  --region ap-southeast-2 \
  --alarm-name meta-gallery-app-cpu-high \
  --metric-name CPUUtilization \
  --monitored-resource-name meta-gallery-app \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --threshold 80 \
  --evaluation-periods 2 \
  --datapoints-to-alarm 2 \
  --treat-missing-data notBreaching
  # 수신처 확정 후 추가: --contact-protocols Email --notification-triggers ALARM

# 알람 2: burst 잔량
aws lightsail put-alarm \
  --region ap-southeast-2 \
  --alarm-name meta-gallery-app-burst-low \
  --metric-name BurstCapacityPercentage \
  --monitored-resource-name meta-gallery-app \
  --comparison-operator LessThanOrEqualToThreshold \
  --threshold 20 \
  --evaluation-periods 2 \
  --datapoints-to-alarm 2 \
  --treat-missing-data notBreaching

# 알람 3: 네트워크 송신량 (5분 합계 기준 임계값은 실측 1주 후 재조정)
#          micro_3_2 포함 전송량은 월 1TB다(2TB 아님).
aws lightsail put-alarm \
  --region ap-southeast-2 \
  --alarm-name meta-gallery-app-netout-high \
  --metric-name NetworkOut \
  --monitored-resource-name meta-gallery-app \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --threshold 2500000000 \
  --evaluation-periods 1 \
  --datapoints-to-alarm 1 \
  --treat-missing-data notBreaching

# 알람 4: 인스턴스 상태 점검
aws lightsail put-alarm \
  --region ap-southeast-2 \
  --alarm-name meta-gallery-app-status-failed \
  --metric-name StatusCheckFailed \
  --monitored-resource-name meta-gallery-app \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --threshold 1 \
  --evaluation-periods 1 \
  --datapoints-to-alarm 1 \
  --treat-missing-data breaching
```

- 알람 3의 임계값 `2500000000`(2.5GB/5분)은 **임시값**이다. `micro_3_2`의 포함 전송량 **1TB/월**을
  30일로 나누면 하루 약 34GB, 5분당 약 119MB가 평균선이다(한도가 2TB에서 1TB로 줄어 평균선도 절반이다).
  운영 1주 실측 후 평균의 3~5배로 다시 잡는다.
- Lightsail 알람은 **지표당 최대 2개**, 계정/리전당 개수 제한이 있다. 위 4개는 지표가 모두 달라 문제없다.
- 알람 자체는 무료다(Lightsail 기본 모니터링 포함). 이메일 알림도 과금 없음 — **재무팀 검증 대상**.

## 3. 2층 — `scripts/ops/healthcheck.sh`

### 3-1. 점검 항목과 임계값

| 점검 이름 | 내용 | WARN | CRIT | 환경변수 |
|---|---|---|---|---|
| `disk-root` | `/` 사용률 | 80% | 90% | `DISK_WARN` / `DISK_CRIT` |
| `disk-inode` | `/` inode 사용률 | 80% | 90% | `INODE_WARN` / `INODE_CRIT` |
| `memory` | `MemAvailable` 기준 사용률 | 85% | 95% | `MEM_WARN` / `MEM_CRIT` |
| `swap` | swap 사용률 (없으면 WARN) | 50% | 80% | `SWAP_WARN` / `SWAP_CRIT` |
| `nginx` | 유닛 active | - | 비active | - |
| `postgresql` | 유닛 active | - | 비active | - |
| `duckdns-timer` | `duckdns-update.timer` active | 비active | - | - |
| `certbot-timer` | `certbot.timer` active | 비active | - | - |
| `postgres` | `pg_isready -h 127.0.0.1` | - | 무응답 | - |
| `postgres-metagallery_prod` / `_dev` | `SELECT 1` | - | 실패 | - |
| `healthz-prod` / `healthz-dev` | `Host:` 헤더로 로컬 nginx `/healthz` | 401 | 200 아님 | - |
| `cert-prod` / `cert-dev` | 인증서 남은 일수 | 20일 이하 | 7일 이하 | `CERT_WARN_DAYS` / `CERT_CRIT_DAYS` |
| `backup-prod` / `backup-dev` | 최신 `pg_dump` 경과 시간 | 36시간 초과 | - | `BACKUP_MAX_AGE_H` |

- `/healthz`는 외부 DNS를 타지 않고 `127.0.0.1`에 `Host` 헤더를 붙여 묻는다. DuckDNS 장애와 앱 장애를 구분하기 위함이다.
- 개발계 `/healthz`가 **401**이면 WARN이다. 감시용으로 `/healthz`만 `auth_basic off`가 필요하다 → nginx 담당(팀원3) 확인 사항.
- 메모리 임계가 1GB 인스턴스에서는 쉽게 걸릴 수 있다. 운영 1주 실측 후 조정한다.
- 확인할 수 없는 항목은 `SKIP`으로 남기고 **종료 코드에 넣지 않는다**(발급 전 인증서, 미설치 PostgreSQL 등).

### 3-2. 종료 코드와 로그

| 종료 코드 | 뜻 |
|---|---|
| 0 | 전부 OK (또는 SKIP만 있음) |
| 1 | WARN 1건 이상 |
| 2 | CRIT 1건 이상 |

- 출력 형식: `2026-11-13T00:00:00Z WARN disk-root 85% (주의 80%)`
- stdout은 systemd journal로 들어간다. 추가로 `/var/log/meta-gallery/healthcheck.log`에 append 한다
  (디렉터리가 없거나 쓸 수 없으면 조용히 건너뛰고 journal만 남긴다).
- 마지막 줄에 `summary CRIT=n WARN=n SKIP=n`을 남겨 journal에서 한 줄 grep으로 추세를 볼 수 있다.

### 3-3. 설치와 5분 주기 등록

```bash
sudo install -d -o root -g root -m 0755 /var/log/meta-gallery
sudo install -o root -g root -m 0750 scripts/ops/healthcheck.sh /usr/local/sbin/healthcheck.sh
sudo /usr/local/sbin/healthcheck.sh --no-log     # 먼저 수동 실행으로 결과 확인
```

5분 주기 유닛은 아래 내용이고, **아래 두 블록은 실제 파일로 납품돼 있다**(팀장 검수 2026-11-13 확인).
저장소에서 그대로 복사해 쓰면 된다 — 아래 ini 블록과 파일 내용은 일치한다.

- `infra/server/systemd/meta-gallery-healthcheck.service`
- `infra/server/systemd/meta-gallery-healthcheck.timer`

```bash
sudo install -o root -g root -m 0644 \
  infra/server/systemd/meta-gallery-healthcheck.service \
  infra/server/systemd/meta-gallery-healthcheck.timer /etc/systemd/system/
```

`provision.sh`는 이 두 유닛을 설치하지 않는다(`healthcheck.sh`가 `scripts/ops/` 소유라 경계를 나눴다).
아래 절차로 직접 설치·활성화한다.

```ini
# /etc/systemd/system/meta-gallery-healthcheck.service
[Unit]
Description=Meta Gallery instance healthcheck
After=network-online.target nginx.service postgresql.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/healthcheck.sh
User=root
UMask=0077
# 종료 코드 1(WARN)/2(CRIT)를 실패로 기록해 journal에서 눈에 띄게 한다
SuccessExitStatus=0
StandardOutput=journal
StandardError=journal
SyslogIdentifier=meta-gallery-healthcheck
```

```ini
# /etc/systemd/system/meta-gallery-healthcheck.timer
[Unit]
Description=Run Meta Gallery healthcheck every 5 minutes

[Timer]
Unit=meta-gallery-healthcheck.service
OnBootSec=3min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now meta-gallery-healthcheck.timer
systemctl list-timers meta-gallery-healthcheck.timer --no-pager
```

## 4. 로그 보관

| 로그 | 경로 | 보관 |
|---|---|---|
| nginx access/error | `/var/log/nginx/meta-gallery-{prod,dev}.{access,error}.log` | logrotate 14일 → `s3://<BACKUPS_BUCKET>/nginx/` 아카이브 |
| healthcheck | `/var/log/meta-gallery/healthcheck.log` | logrotate 14일, 압축, S3 아카이브 불필요 |
| duckdns / certbot | journald | `journalctl` 기본 보관(`SystemMaxUse` 기본값) |

- logrotate 설정 파일(`infra/server/logrotate/meta-gallery`)은 **인프라팀 팀원3 소유**다.
  `/var/log/meta-gallery/healthcheck.log` 항목(daily / rotate 14 / compress)은
  **팀장 검수 2026-11-13에 추가 완료**됐다(원래 요청: 7절).
- journald 용량 상한(`/etc/systemd/journald.conf`의 `SystemMaxUse=200M` 권고)은 40GB 디스크 보호용으로 함께 검토한다.

## 5. 장애 시 확인 순서 (런북)

1. 사이트가 안 열린다 → `https://metagallery.duckdns.org` 와 `http://<고정 IP>` 를 각각 열어 본다.
   - 고정 IP는 되고 도메인은 안 되면 **DuckDNS 쪽 문제**다 → `systemctl status duckdns-update.timer`, `journalctl -u duckdns-update`
   - 둘 다 안 되면 인스턴스/nginx 문제다 → Lightsail 콘솔에서 인스턴스 상태 확인
2. SSH 접속 → `sudo /usr/local/sbin/healthcheck.sh --no-log` 로 CRIT 항목 확인
3. 인증서 경고 → `sudo /usr/local/sbin/issue-certificates.sh prod --verify-only`
4. 디스크 가득 → `du -xh --max-depth=2 /srv /var | sort -h | tail -20` 로 범인을 찾는다.
   오래된 릴리스 정리는 배포 스크립트 담당(팀원1) 롤백 경로를 확인한 뒤에 한다.
5. 배포 직후 장애면 **되돌리기부터** 한다 → `scripts/deploy/rollback.sh`(팀원1 산출물)

## 6. 아직 없는 것 (알려진 구멍)

- **외부 업타임 감시가 없다.** 인스턴스가 통째로 멈추면 Lightsail 알람은 뜨지만 그걸 받을 수신처가
  아직 정해지지 않았다. 외부 서비스(UptimeRobot 등) 사용은 가입·개인정보가 걸려 **CEO 결정 대기**다.
- **호출(paging) 체계가 없다.** 야간 장애를 자동으로 알릴 경로가 없다.
- **지표 대시보드가 없다.** Lightsail 콘솔 그래프를 눈으로 본다. CloudWatch 연동은 비용이 붙어 보류한다.
- **DuckDNS 자체 장애는 감시 대상이 아니다**(무료 서비스, SLA 없음). 고정 IP 직접 접속이 임시 대응이다.
- healthcheck 결과를 **알림으로 보내지 않는다.** 로그에만 남는다. 알림 경로가 정해지면
  `healthcheck.sh` 종료 코드를 받아 보내는 래퍼를 추가한다.

## 7. 다른 팀에 요청할 것

→ `docs/infra/handoff-requests.md` 로 정리했다. 모니터링 관련 요청 요약:

- 인프라팀 팀원3: nginx `/healthz`에 `auth_basic off` 적용, logrotate에 `/var/log/meta-gallery/*.log` 추가
- 애플리케이션보안팀: 알람 수신 이메일·외부 감시 서비스 사용 시 개인정보/보안 검토
- 재무팀: Lightsail 알람·이메일 알림이 무과금이라는 가정 검증

## 변경 이력

- 2026-11-13: 최초 작성(IT본부 인프라팀 팀원4)
- 2026-11-13: 팀장 검수 — 3-3의 "유닛 파일을 넣지 않았다" 서술을 실제 납품 파일
  (`infra/server/systemd/meta-gallery-healthcheck.{service,timer}`) 안내로 교체.
  4절 healthcheck.log logrotate 항목이 추가 완료됨을 반영.
- 2026-11-13: CEO 발급값에 맞춰 DuckDNS 호스트명 교체 — 하이픈 있는 옛 이름(`meta-gallery` / `meta-gallery-dev` + `.duckdns.org`)에서 `metagallery.duckdns.org` / `metagallery-dev.duckdns.org`로, DuckDNS 서브도메인 이름도 `metagallery` / `metagallery-dev`로 바꿨다. 인스턴스·고정 IP 이름, S3 버킷, 서버 경로, systemd 유닛, nginx 설정 파일명, certbot `--cert-name`, DB·롤 이름은 바꾸지 않았다. 근거: `docs/plans/2026-11-13-aws-infra.md` 1-3 변경 사유.

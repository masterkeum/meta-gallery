# 서버 내부 구성 (Lightsail 인스턴스)

- 날짜: 2026-11-13
- 작성 주체: IT본부 인프라팀 (계획서 `docs/plans/2026-11-13-aws-infra.md` 2장 항목 3)
- 대상: AWS Lightsail `meta-gallery-app` / Ubuntu 24.04 / `micro_3_2` (1GB RAM, 40GB SSD, 월 전송량 1TB) / 시드니 `ap-southeast-2a`
- 상태: **설계·스크립트만 작성한 단계다.** 실제 인스턴스가 없어 어떤 명령도 실행하지 않았다.

---

## 1. 산출물과 설치 위치

| 저장소 파일 | 서버 설치 위치 | 권한 | 설치 주체 |
|---|---|---|---|
| `infra/server/nginx/meta-gallery-prod.conf` | `/etc/nginx/sites-available/meta-gallery-prod.conf` | 0644 root:root | provision.sh |
| `infra/server/nginx/meta-gallery-dev.conf` | `/etc/nginx/sites-available/meta-gallery-dev.conf` | 0644 root:root | provision.sh |
| `infra/server/systemd/meta-gallery-api@.service` | `/etc/systemd/system/meta-gallery-api@.service` | 0644 root:root | provision.sh (enable 안 함) |
| `infra/server/systemd/meta-gallery-backup.service` | `/etc/systemd/system/meta-gallery-backup.service` | 0644 root:root | provision.sh |
| `infra/server/systemd/meta-gallery-backup.timer` | `/etc/systemd/system/meta-gallery-backup.timer` | 0644 root:root | provision.sh (enable 함) |
| `infra/server/systemd/meta-gallery-healthcheck.service` | `/etc/systemd/system/meta-gallery-healthcheck.service` | 0644 root:root | **수동** (monitoring.md 3-3) |
| `infra/server/systemd/meta-gallery-healthcheck.timer` | `/etc/systemd/system/meta-gallery-healthcheck.timer` | 0644 root:root | **수동** (monitoring.md 3-3) |
| `infra/server/postgres/init-databases.sql` | (임시 복사 후 psql 실행) | - | provision.sh |
| `infra/server/scripts/backup-postgres.sh` | `/usr/local/sbin/backup-postgres.sh` | 0750 root:root | provision.sh |
| `infra/server/scripts/restore-postgres.sh` | `/usr/local/sbin/restore-postgres.sh` | 0750 root:root | provision.sh |
| `infra/server/logrotate/meta-gallery` | `/etc/logrotate.d/meta-gallery` | 0644 root:root | provision.sh |
| `infra/server/env/prod.env.example` | `/etc/meta-gallery/prod.env` (자리표시자 치환) | **0600 root:root** | provision.sh |
| `infra/server/env/dev.env.example` | `/etc/meta-gallery/dev.env` (자리표시자 치환) | **0600 root:root** | provision.sh |
| (스크립트가 생성) | `/etc/meta-gallery/backup.env` | 0600 root:root | provision.sh |
| (스크립트가 생성) | `/etc/sudoers.d/meta-gallery-deploy` | 0440 root:root | provision.sh |
| (스크립트가 생성) | `/etc/postgresql/16/main/conf.d/10-meta-gallery.conf` | 0644 postgres | provision.sh |
| (스크립트가 생성) | `/etc/postgresql/16/main/pg_hba.conf` | 0640 postgres | provision.sh |
| (스크립트가 생성) | `/etc/nginx/.htpasswd-meta-gallery-dev` | 0640 root:www-data | provision.sh |
| (스크립트가 생성) | `/etc/sysctl.d/60-meta-gallery.conf` | 0644 root:root | provision.sh |

`*.env` 실제 파일은 **서버에만 존재한다.** 저장소에는 `*.env.example`(자리표시자)만 둔다.

## 2. 디렉터리 구조

```
/srv/meta-gallery/                      0755 root:mgweb
  prod/                                 2750 deploy:mgweb
    releases/<git-sha>/                 ← 배포 단위(불변)
    releases/0000-bootstrap/            ← 첫 배포 전 nginx 기동용 안내 페이지
    current -> releases/<git-sha>       ← 심볼릭 링크 교체로 무중단 전환
    shared/                             ← 릴리스 간 공유(런타임 쓰기 허용 경로)
  dev/                                  (prod 와 동일 구조)

/etc/meta-gallery/
  prod.env, dev.env                     0600 root:root (DATABASE_URL 등)
  backup.env                            0600 root:root (S3 설정·자격증명)
  dev-basic-auth.txt                    0600 root:root (전달 후 삭제)

/var/log/nginx/meta-gallery-{prod,dev}.{access,error}.log
/var/log/meta-gallery/backup.log
/var/backups/meta-gallery/{prod,dev}/   0700 root:root  (pg_dump 로컬 보관)
/var/backups/meta-gallery/provision/    0700 root:root  (설정 교체 시 원본 백업)
/var/www/certbot/                   0755 root:www-data (HTTP-01 webroot)
```

- 소유: `deploy`(그룹 `mgweb`)가 `/srv/meta-gallery` 하위를 소유한다. 그룹 setgid(2750)로
  새 파일도 `mgweb` 그룹을 물려받아 nginx(`www-data`, `mgweb` 보조그룹)가 읽을 수 있다.
- `deploy`는 **심볼릭 링크 교체에 sudo가 필요 없다**(자기 소유 디렉터리). sudoers에는
  `systemctl reload nginx`·`nginx -t`·`systemctl is-active nginx`만 넣었다.

## 3. 환경 분리 요약 (계획서 1-2 고정값)

| 구분 | prod | dev |
|---|---|---|
| server_name | `metagallery.duckdns.org` | `metagallery-dev.duckdns.org` |
| 정적 루트 | `/srv/meta-gallery/prod/current` | `/srv/meta-gallery/dev/current` |
| 백엔드 포트 | `127.0.0.1:3000` | `127.0.0.1:3001` |
| systemd | `meta-gallery-api@prod.service` | `meta-gallery-api@dev.service` |
| DB / 롤 | `metagallery_prod` / `mg_prod` | `metagallery_dev` / `mg_dev` |
| 헬스체크 | `/healthz` (nginx가 직접 200) | `/healthz` (Basic 인증 면제) |
| 접근 제한 | 없음(공개) | HTTP Basic + `X-Robots-Tag: noindex` |

- 외부로 열리는 포트는 nginx의 80·443뿐이다. 백엔드와 PostgreSQL은 루프백 전용이다.
- 두 호스트명이 같은 고정 IP를 가리키고, 분기는 nginx `server_name`이 한다.

## 4. 실행 순서 (CEO 승인 후)

```bash
# 0. 전제: Lightsail 인스턴스 생성(팀원2 Terraform), 고정 IP 연결, 22번 포트 관리자 IP만 허용
ssh ubuntu@<고정IP>
sudo apt-get update && sudo apt-get install -y git
git clone <저장소> /opt/meta-gallery-src     # 또는 scp 로 저장소 전송

# 1. 무엇이 바뀌는지 먼저 본다 (변경 없음)
sudo bash /opt/meta-gallery-src/infra/server/scripts/provision.sh --dry-run

# 2. 실제 프로비저닝 (확인 프롬프트에 yes 입력)
sudo bash /opt/meta-gallery-src/infra/server/scripts/provision.sh

# 3. 자체 확인
curl -sI http://127.0.0.1/healthz -H 'Host: metagallery.duckdns.org'
curl -sI http://127.0.0.1/healthz -H 'Host: metagallery-dev.duckdns.org'
sudo systemctl status nginx postgresql --no-pager
sudo systemctl list-timers meta-gallery-backup.timer --no-pager
swapon --show
sudo runuser -u postgres -- psql -c '\l'
sudo /usr/local/sbin/backup-postgres.sh all --dry-run
```

`provision.sh`는 멱등하다. 다시 실행해도 기존 `*.env`의 비밀번호와 `current` 심링크는
건드리지 않고, 교체되는 설정 파일은 `/var/backups/meta-gallery/provision/<타임스탬프>/`에
원본을 남긴다. 파일을 삭제하지 않는다.

## 5. HTTPS 전환 순서 (인증서가 없는 상태에서 먼저 뜨게 하는 이유)

certbot HTTP-01 챌린지는 **80 포트가 먼저 떠 있어야** 통과한다. 그런데 nginx는 존재하지
않는 인증서 경로를 가리키는 `ssl_certificate`가 있으면 기동 자체에 실패한다. 그래서 두
사이트 설정을 3개 블록으로 나눠 두었다.

| 블록 | 내용 | STAGE 1 (인증서 전) | STAGE 2 (인증서 후) |
|---|---|---|---|
| `[A]` | 80 포트 + 사이트 전체 + acme webroot | **활성** | 주석 처리 |
| `[B]` | 443 포트 + 사이트 전체 (TLS) | 주석 | **주석 해제** |
| `[C]` | 80 포트 + acme webroot + 301 리다이렉트 | 주석 | **주석 해제** |

```bash
# STAGE 1 : provision.sh 가 여기까지 해 둔다. HTTP로 사이트가 보인다.
#   webroot = /var/www/certbot
#   확인용 파일 응답 테스트:
sudo install -d -o root -g www-data -m 0755 /var/www/certbot/.well-known/acme-challenge
echo ping | sudo tee /var/www/certbot/.well-known/acme-challenge/ping >/dev/null
curl -s http://metagallery.duckdns.org/.well-known/acme-challenge/ping   # ping 이 나와야 한다

# STAGE 1.5 : DuckDNS 레코드가 고정 IP를 가리키는지 먼저 확인 (팀원4 담당)
dig +short metagallery.duckdns.org
dig +short metagallery-dev.duckdns.org

# STAGE 1.6 : 인증서 발급 (팀원4의 scripts/ops/issue-certificates.sh)
#   staging --dry-run → 본 발급 순서를 지킨다. 환경별로 따로 발급한다.
#   이 스크립트는 --cert-name meta-gallery-prod / meta-gallery-dev 로 발급하므로
#   인증서 경로가 호스트명이 아니라 인증서 이름이 된다.

# STAGE 2 : 블록 전환 후 반드시 문법 검증 → reload
sudo cp /etc/nginx/sites-available/meta-gallery-prod.conf \
        /var/backups/meta-gallery/provision/meta-gallery-prod.conf.stage1
sudo nano /etc/nginx/sites-available/meta-gallery-prod.conf   # [A] 주석, [B][C] 해제
sudo nginx -t && sudo systemctl reload nginx
curl -sI https://metagallery.duckdns.org/healthz
# dev 도 같은 방법으로 전환
```

- 개발계 `[A]`·`[B]`에서 `/.well-known/acme-challenge/`와 `/healthz`는 `auth_basic off`다.
  Basic 인증을 켜 두면 챌린지와 배포 헬스체크가 모두 실패한다. **이 두 예외를 지워서는 안 된다.**
- HSTS(`Strict-Transport-Security`)는 켜면 되돌리기 어렵다(브라우저가 기간 내 HTTP 접속을
  거부). 주석 상태로 두었고, 운영이 안정된 뒤 애플리케이션보안팀 검토를 받고 켠다.
- 갱신은 certbot 패키지 타이머에 맡기고 `--deploy-hook`으로 `systemctl reload nginx`를 건다(팀원4).
- **webroot와 인증서 경로는 팀원4의 발급 스크립트에 맞춘 값이다**(계획서 1장에 없던 값).
  - webroot: `/var/www/certbot` (`scripts/ops/issue-certificates.sh` 의 `WEBROOT` 기본값)
  - 인증서: `/etc/letsencrypt/live/meta-gallery-prod/`, `/etc/letsencrypt/live/meta-gallery-dev/`
    (`--cert-name meta-gallery-{prod,dev}` 기준. **호스트명 디렉터리가 아니다**)
  - 발급 스크립트에서 `WEBROOT`나 `--cert-name`을 바꾸면 nginx 설정 2개와 `provision.sh`의
    `ACME_WEBROOT`도 같이 바꿔야 한다.

## 6. PostgreSQL

- Ubuntu 24.04 기본 저장소의 PostgreSQL 16. PGDG 저장소를 추가하지 않는다.
- `listen_addresses = 'localhost'`, 포트 5432. Lightsail 방화벽에 5432를 열지 않는다.
- `pg_hba.conf`: `local` = `peer`, `127.0.0.1/32`·`::1/128` = `scram-sha-256`. 외부 항목 없음.
- 1GB RAM 기준 튜닝: `max_connections=40`, `shared_buffers=128MB`,
  `effective_cache_size=384MB`, `work_mem=4MB`. 롤별 `CONNECTION LIMIT`은 prod 15 / dev 10.

### 환경별 격리 방식

- DB 소유자는 `postgres`다. 앱 롤이 DB 소유자면 회수한 권한을 스스로 되돌릴 수 있다.
- `REVOKE ALL ON DATABASE <db> FROM PUBLIC` 후 **자기 환경 롤에만** `CONNECT, TEMPORARY`를 준다.
  `mg_dev`에게 `metagallery_prod` CONNECT를 주지 않는 것이 교차 접근 차단의 핵심이다.
- 각 DB에서 `REVOKE CREATE ON SCHEMA public FROM PUBLIC`. 테이블은 롤이 소유한 `app`
  스키마에 만들고, `ALTER ROLE ... IN DATABASE ... SET search_path = app, public`으로 고정했다.
- 확인:
  ```bash
  sudo runuser -u postgres -- psql -c \
    "SELECT datname, datacl FROM pg_database WHERE datname LIKE 'metagallery%'"
  # mg_dev 가 운영계에 못 붙는지 직접 확인 (비밀번호 입력 시 실패해야 정상)
  psql "postgresql://mg_dev@127.0.0.1:5432/metagallery_prod"   # permission denied 기대
  ```
- **남은 구멍(애플리케이션보안팀 검토 대상)**: 기본값으로 `PUBLIC`은 유지보수용 `postgres`
  DB에 CONNECT할 수 있다. 상대 환경의 데이터는 못 읽지만 `pg_catalog` 메타데이터는 볼 수
  있다. 더 조이는 SQL은 `init-databases.sql` 7번 주석에 적어 두었고, 지금은 적용하지 않았다.

### 비밀번호 취급

- `init-databases.sql`에는 비밀번호가 없다. 롤을 비밀번호 없이 만든다.
- `provision.sh`가 `openssl rand`로 영숫자 40자를 만들고,
  `ALTER ROLE`을 **stdin(heredoc)으로만** 보낸다(인자로 주면 `ps`에 평문이 보인다).
- `log_statement = 'none'`이라 PostgreSQL 로그에도 남지 않는다.
- `/etc/meta-gallery/{prod,dev}.env`(0600 root:root)의 `DATABASE_URL`로만 전달한다.
  예시 파일의 자리표시자 치환은 외부 명령 없이 bash 문자열 치환으로 해서 argv 노출이 없다.
- 비밀번호를 바꿀 때는 env 파일을 지우지 말고, 새 비밀번호로 `ALTER ROLE` → env 파일 갱신 →
  `systemctl restart meta-gallery-api@<env>` 순서로 한다. 교체 주기는 애플리케이션보안팀 검토 사항.

## 7. 백업과 복구

### 백업 (자동)

- `meta-gallery-backup.timer` → 매일 **03:10 KST**(`OnCalendar=*-*-* 03:10:00 Asia/Seoul`,
  `Persistent=true`, 최대 2분 랜덤 지연) → `meta-gallery-backup.service` →
  `/usr/local/sbin/backup-postgres.sh all`
- 흐름: `pg_dump -Fc`(postgres 권한, 출력 리다이렉트는 root) → `/var/backups/meta-gallery/<env>/`
  에 `metagallery_<env>-YYYYmmddTHHMMSS+0900.dump` + `.sha256` →
  `aws s3 cp` → `s3://<백업버킷>/postgres/<env>/YYYY/MM/DD/` → 로컬 7일 보관 정리
- 로컬 정리 안전장치: 지정 디렉터리 `maxdepth 1` + 이름 패턴 + **최신 3개는 항상 유지** +
  S3 업로드가 확인되지 않으면 정리 생략. `rm -rf`나 `--force`는 쓰지 않고 파일 하나씩 `rm --`.
- S3 업로드는 **기본 꺼져 있다**(`/etc/meta-gallery/backup.env`의 `S3_ENABLED=0`).
  켜려면 버킷 이름과 자격증명이 필요하다. Lightsail에는 IAM 인스턴스 역할을 붙일 수 없어
  백업 버킷 `PutObject` 전용 IAM 사용자 액세스 키가 필요하다 → 애플리케이션보안팀 검토 대상.
- 추가로 Lightsail 자동 스냅샷(일 1회)으로 인스턴스 전체를 보호한다(팀원2 Terraform).

```bash
sudo /usr/local/sbin/backup-postgres.sh all --dry-run     # 변경 없이 점검
sudo /usr/local/sbin/backup-postgres.sh prod              # 수동 1회
sudo systemctl start meta-gallery-backup.service          # 타이머와 같은 경로로 실행
journalctl -u meta-gallery-backup.service -n 50 --no-pager
sudo tail -n 50 /var/log/meta-gallery/backup.log
```

### 복구 (수동, 되돌릴 수 없음)

```bash
# 1. 덤프 내용 확인 (변경 없음)
sudo /usr/local/sbin/restore-postgres.sh --file /var/backups/meta-gallery/prod/<파일>.dump --list

# 2. 권장: 새 DB로 복구해서 내용을 먼저 검증한다 (운영 DB 무영향)
sudo /usr/local/sbin/restore-postgres.sh \
     --file /var/backups/meta-gallery/prod/<파일>.dump --into-new metagallery_prod_restore_test

# 3. 운영 DB 덮어쓰기 (대상 DB 이름과 'RESTORE' 를 손으로 입력해야 진행된다)
sudo systemctl stop meta-gallery-api@prod.service        # 백엔드가 생긴 뒤에만 필요
sudo /usr/local/sbin/restore-postgres.sh \
     --file /var/backups/meta-gallery/prod/<파일>.dump --overwrite prod --disconnect-sessions
sudo systemctl start meta-gallery-api@prod.service
```

- `--overwrite`는 `pg_restore --clean --if-exists`로 기존 객체를 지운다. 그래서
  **(1)** 대화식이면 DB 이름 + `RESTORE` 2단 확인, **(2)** 비대화식이면 `--confirm-db <DB이름>`과
  `META_GALLERY_RESTORE_CONFIRM=yes` 둘 다 필요, **(3)** 실행 전 자동으로
  `<db>-pre-restore-<시각>.dump` 안전 백업을 뜬다. `--force` 류 플래그는 제공하지 않는다.
- S3에서 받아올 때:
  `aws s3 cp s3://<버킷>/postgres/prod/2026/11/13/<파일>.dump /var/backups/meta-gallery/prod/`
- **운영 데이터를 개발계로 복사하는 것은 기본 차단**이다(계획서 3-2). 파일명으로 원본 환경을
  판별해 교차 복구를 거부하고, `--allow-cross-env`를 명시해야 진행하며 경고를 로그에 남긴다.

## 8. 로그

- nginx: 14일 보관(daily, compress). 회전 시 `kill -USR1`로 재오픈하므로 무중단이다.
- 회전된 `.gz`는 `backup.env`의 `S3_ENABLED=1`일 때 `aws s3 sync`로 백업 버킷
  `nginx-logs/`에 아카이브한다. 업로드만 하고 로컬 삭제는 `rotate 14`가 담당한다.
- `backup.log`는 주간 회전 8회 보관.
- **설치 후 점검 필요**: Ubuntu 기본 `/etc/logrotate.d/nginx`가 `/var/log/nginx/*.log`를
  포괄하므로 meta-gallery 로그가 두 설정에 중복될 수 있다. 중복이면 logrotate가 경고를 낸다.
  ```bash
  sudo logrotate -d /etc/logrotate.d/meta-gallery 2>&1 | grep -i 'duplicate' || echo '중복 없음'
  ```
  중복이면 기본 nginx 설정에서 meta-gallery 로그를 제외하도록 조정한다(기본 파일 수정이
  필요하므로 팀장 확인 후 진행).

## 9. 백엔드 유닛 활성화 절차 (지금은 하지 않는다)

백엔드 코드가 없어 `meta-gallery-api@.service`는 **설치만 했고 enable하지 않았다.**
`ExecStart`는 실수로 start되면 즉시 `EX_CONFIG(78)`로 실패하는 자리표시자다.
정적 서비스는 백엔드 없이 동작하고, 백엔드 미기동 시 영향은 `/api/` 경로의 502뿐이다.

백엔드팀 산출물이 나오면:

```bash
sudo nano /etc/systemd/system/meta-gallery-api@.service   # ExecStart 교체
sudo systemd-analyze verify meta-gallery-api@prod.service
sudo systemctl daemon-reload
sudo systemctl enable --now meta-gallery-api@prod.service
curl -s http://127.0.0.1:3000/healthz
```

함께 확인할 것: 런타임·버전(Node 등), 엔트리포인트 경로, `PORT` 환경변수 수용 여부,
헬스체크 엔드포인트 형식, 쓰기가 필요한 경로(현재 `shared/`만 허용),
`MemoryMax=256M`로 충분한지, WebSocket 사용 여부.

WebSocket으로 가면 `$connection_upgrade` map이 필요하다. 이 map을 `sites-available`에 두면
prod/dev 양쪽에서 중복 정의돼 nginx가 뜨지 않으므로, `http` 컨텍스트
(`/etc/nginx/conf.d/websocket-upgrade.conf`)에 **한 번만** 정의해야 한다. 해당 파일은 이번
산출물 범위가 아니라 주석으로만 표시해 두었다.

## 9-2. 모니터링 유닛 (팀원4 본문을 파일로 옮긴 것)

`meta-gallery-healthcheck.service`·`.timer`는 **팀원4가 `docs/infra/monitoring.md` 3-3에 적은
본문을 그대로 옮긴 파일**이다(내용 변경 없음). 파일 소유 경로가 `infra/server/systemd/`라
팀원3이 파일로 만들었을 뿐이고, 설치·활성화 절차와 임계값 설계는 `monitoring.md` 3-3이 기준이다.

`provision.sh`는 이 두 유닛을 **설치하지 않는다.** 실행 대상인 `healthcheck.sh`가 팀원4 소유
경로(`scripts/ops/`)에 있어 설치 주체를 섞지 않았다. 설치는 `monitoring.md` 3-3의 명령을 따른다.

```bash
sudo install -o root -g root -m 0750 scripts/ops/healthcheck.sh /usr/local/sbin/healthcheck.sh
sudo install -o root -g root -m 0644 infra/server/systemd/meta-gallery-healthcheck.service /etc/systemd/system/
sudo install -o root -g root -m 0644 infra/server/systemd/meta-gallery-healthcheck.timer   /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now meta-gallery-healthcheck.timer
```

## 10. 확인하지 못한 것

- **nginx 설정 문법 검증(`nginx -t`)을 하지 못했다.** 로컬 맥에 nginx가 없고, 설치는
  지시 범위를 벗어난다. 서버에서 `provision.sh`가 `nginx -t` 통과를 전제로만 reload한다.
- **PostgreSQL SQL 실행 검증을 하지 못했다.** 로컬에 PostgreSQL 서버가 없다(psql 클라이언트만
  있다). `init-databases.sql`의 실제 동작은 서버에서 확인해야 한다.
- **systemd 유닛 검증(`systemd-analyze verify`)을 하지 못했다.** macOS에는 systemd가 없다.
- **logrotate 문법 검증(`logrotate -d`)을 하지 못했다.** 같은 이유다.
- 셸 스크립트는 `bash -n`과 `shellcheck`로만 확인했다. 실제 실행은 하지 않았다.
- 릴리스 디렉터리의 진입 파일 이름이 `index.html`인지 `meta-gallery.html`인지 확정되지
  않았다(`scripts/build-standalone.py`는 `dist/meta-gallery.html`을 만든다). nginx `index`
  지시자에 두 이름을 모두 넣어 두었지만, 배포 스크립트(팀원1)와 맞춰야 한다.

## 11. 변경 이력

- 2026-11-13: 최초 작성 (IT본부 인프라팀, 계획서 2장 항목 3)
- 2026-11-13: 팀원4 확정값 반영 — ACME webroot `/var/www/letsencrypt` → `/var/www/certbot`,
  인증서 경로를 호스트명에서 `--cert-name`(`meta-gallery-prod`/`meta-gallery-dev`) 기준으로 변경,
  운영계 ACME 경로에 `auth_basic off` 추가, 모니터링 유닛 2개를 `monitoring.md` 3-3에서 파일로 옮김
- 2026-11-13: CEO 발급값에 맞춰 DuckDNS 호스트명 교체 — 하이픈 있는 옛 이름(`meta-gallery` / `meta-gallery-dev` + `.duckdns.org`)에서 `metagallery.duckdns.org` / `metagallery-dev.duckdns.org`로, DuckDNS 서브도메인 이름도 `metagallery` / `metagallery-dev`로 바꿨다. 인스턴스·고정 IP 이름, S3 버킷, 서버 경로, systemd 유닛, nginx 설정 파일명, certbot `--cert-name`, DB·롤 이름은 바꾸지 않았다. 근거: `docs/plans/2026-11-13-aws-infra.md` 1-3 변경 사유.

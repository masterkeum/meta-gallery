# DuckDNS keepalive 갱신 (meta-gallery)

- 날짜: 2026-11-13
- 작성 주체: IT본부 인프라팀 (팀원 4)
- 근거 계획: `docs/plans/2026-11-13-aws-infra.md` 1-3

## 1. 무엇을 하는 구성인가

| 파일 | 설치 위치 | 역할 |
|---|---|---|
| `duckdns-update.sh` | `/usr/local/sbin/duckdns-update.sh` (root:root 0755) | DuckDNS update API 1회 호출 |
| `duckdns-update.service` | `/etc/systemd/system/duckdns-update.service` | oneshot 실행 유닛 |
| `duckdns-update.timer` | `/etc/systemd/system/duckdns-update.timer` | 5분 주기 호출 |

대상 호스트명 2개 (계획 1-3 고정값):

| 환경 | 호스트명 | DuckDNS 서브도메인 이름 |
|---|---|---|
| 운영계 | `metagallery.duckdns.org` | `metagallery` |
| 개발계 | `metagallery-dev.duckdns.org` | `metagallery-dev` |

두 서브도메인은 **같은 Lightsail 고정 IP**를 가리킨다. 환경 분기는 nginx `server_name`이 한다
(nginx 설정은 인프라팀 팀원3 산출물 `infra/server/nginx/`).

**IPv6**: 인스턴스가 `ip_address_type = "ipv4"`(`infra/terraform/lightsail.tf`)이므로 DuckDNS
계정 페이지의 IPv6 칸은 **비워 둔다**(갱신 스크립트도 `ipv6` 파라미터를 보내지 않는다). 값을 넣으면
AAAA 레코드가 생겨 IPv6 클라이언트가 응답 없는 주소로 접속을 시도한다.

## 2. 왜 5분마다 도는가

Lightsail 고정 IP라서 IP가 바뀌지 않는다. 그래도 타이머를 두는 이유는 **DuckDNS가 장기간
갱신 요청이 없는 도메인을 회수**하기 때문이다. 즉 IP 갱신이 아니라 소유권 유지(keepalive)가 목적이다.
요청 1회는 수 KB 수준이라 월 전송량 한도(`micro_3_2` 포함 1TB)에 영향이 없다.

## 3. 토큰 등록 절차 (셸 히스토리에 남기지 않는 방법)

> 토큰 발급은 **CEO가 직접** 한다. 인프라팀은 외부 서비스에 가입하지 않는다.
> 아래 절차는 CEO가 발급한 토큰을 서버에 넣는 방법이다.

```bash
# 1) 디렉터리와 빈 파일을 먼저 0600으로 만든다
sudo install -d -o root -g root -m 0700 /etc/meta-gallery
sudo install -o root -g root -m 0600 /dev/null /etc/meta-gallery/duckdns.env

# 2) 편집기로 직접 입력한다 (명령줄에 토큰을 타이핑하지 않으므로 히스토리에 남지 않는다)
sudo nano /etc/meta-gallery/duckdns.env
```

파일 내용:

```sh
# /etc/meta-gallery/duckdns.env  (root:root 0600)
DUCKDNS_TOKEN="<DuckDNS 계정 페이지의 token 값>"
DUCKDNS_DOMAINS="metagallery,metagallery-dev"
# DUCKDNS_IP= 는 비워 둔다. 비우면 DuckDNS가 요청 송신 IP(= Lightsail 고정 IP)를 쓴다.
```

**하지 말 것**

- `echo "DUCKDNS_TOKEN=..." | sudo tee ...` 처럼 명령줄에 토큰을 넣지 말 것 → 셸 히스토리에 남는다.
  부득이하면 그 셸에서만 `set +o history`를 켜고, 끝난 뒤 `history -c`로 정리한다.
- `curl "https://www.duckdns.org/update?...token=..."` 를 손으로 치지 말 것 → 히스토리와 `ps`에 남는다.
  점검은 `sudo duckdns-update.sh --check` / `--dry-run`으로 한다.
- 스크립트를 `bash -x`로 돌리지 말 것 → xtrace 출력에 토큰이 노출된다.

## 4. 토큰이 노출되지 않게 한 방법 (코드에 반영된 것)

| 노출 경로 | 막은 방법 |
|---|---|
| 커맨드라인 인자 | 스크립트는 토큰 인자를 **받지 않는다.** env 파일만 읽는다. |
| `ps` / `/proc/<pid>/cmdline` | `curl --config -`로 토큰이 든 URL을 **표준입력**으로만 넘긴다. argv에 URL이 없다. |
| 서비스 프로세스 환경변수 | `.service`에 `EnvironmentFile=`을 쓰지 않는다. 스크립트가 파일을 직접 파싱한다. |
| 임의 코드 실행 | env 파일을 `source` 하지 않고 `KEY=VALUE` 줄만 꺼낸다. |
| 로그 / 에러 메시지 | 모든 출력이 `redact()`(`sed s/$TOKEN/***REDACTED***/g`)를 거친다. curl 에러도 `2>&1`로 모아 함께 가린다. |
| 잘못된 값 되돌려 출력 | 토큰 검증 실패 메시지에 값을 넣지 않고 길이만 표시한다. |
| 파일 권한 | 그룹·기타 권한 비트가 켜져 있으면 실행을 거부한다(0600/0400만 허용). |
| 디스크 잔존물 | 응답을 임시 파일 없이 변수로 받는다. `umask 077`. |

## 5. 설치

```bash
# 1) 스크립트 배치
sudo install -o root -g root -m 0755 infra/duckdns/duckdns-update.sh /usr/local/sbin/duckdns-update.sh

# 2) 설정 점검 (네트워크 호출 없음)
sudo /usr/local/sbin/duckdns-update.sh --check
sudo /usr/local/sbin/duckdns-update.sh --dry-run

# 3) 수동 1회 갱신 확인
sudo /usr/local/sbin/duckdns-update.sh        # "OK domains=... " 가 나와야 한다

# 4) 유닛 배치와 기동
sudo install -o root -g root -m 0644 infra/duckdns/duckdns-update.service /etc/systemd/system/
sudo install -o root -g root -m 0644 infra/duckdns/duckdns-update.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now duckdns-update.timer

# 5) 동작 확인
systemctl list-timers duckdns-update.timer --no-pager
journalctl -u duckdns-update.service -n 20 --no-pager
```

## 6. 문제 해결

| 증상 | 확인 |
|---|---|
| `KO` 응답 (종료 코드 3) | 토큰이 틀렸거나 해당 서브도메인이 그 계정 소유가 아니다. DuckDNS 계정 페이지의 도메인 목록과 `DUCKDNS_DOMAINS`를 맞춘다. |
| `env 파일 권한이 너무 넓습니다` | `sudo chmod 600 /etc/meta-gallery/duckdns.env` |
| 타이머가 돌지 않음 | `ConditionPathExists=/etc/meta-gallery/duckdns.env` 때문일 수 있다. 파일 존재를 확인한다. |
| HTTP 오류 (종료 코드 2) | 인스턴스 아웃바운드 443이 막혔는지, DuckDNS 자체 장애인지 확인한다. 도메인이 끊긴 동안은 고정 IP로 직접 접속한다. |

## 7. 서브도메인이 선점된 경우 (대체 이름 규칙)

**2026-11-13: CEO가 DuckDNS에 `metagallery`(하이픈 없음)로 발급했다.** 그래서 1순위가
하이픈 없는 이름으로 바뀌었고, 저장소 전체 호스트명도 거기에 맞췄다.
`metagallery-dev` 등록 여부는 **확인하지 못함**(인프라팀은 DuckDNS 계정에 접근하지 않는다).
개발계 이름이 선점돼 있으면 아래 순서로 내려간다.

| 순위 | 운영계 | 개발계 |
|---|---|---|
| 1 (기본, 운영계는 발급 완료) | `metagallery` | `metagallery-dev` |
| 2 | `meta-gallery` | `meta-gallery-dev` |
| 3 | `metagallery-kr` | `metagallery-kr-dev` |
| 4 | `metagallery-web` | `metagallery-web-dev` |

규칙: **운영계 이름을 먼저 확정하고, 개발계는 거기에 `-dev`를 붙인다.** 운영계와 개발계가
서로 다른 어간을 쓰지 않는다(운영 중 혼동 방지). DuckDNS 무료 계정은 서브도메인 5개까지라
여유가 있지만, 2개만 쓰고 나머지는 비워 둔다.

이름이 1순위에서 바뀌면 아래를 **모두** 같이 고쳐야 한다(한 곳만 고치면 인증서 발급이 실패한다).

| 고칠 곳 | 항목 | 담당 |
|---|---|---|
| `docs/plans/2026-11-13-aws-infra.md` 1-3 | 고정값 표 | 인프라팀 팀장 |
| `/etc/meta-gallery/duckdns.env` | `DUCKDNS_DOMAINS` | 서버 운영 |
| `scripts/ops/issue-certificates.sh` | `host_for()` | 인프라팀 팀원4 |
| `scripts/ops/healthcheck.sh` | `PROD_HOST` / `DEV_HOST` | 인프라팀 팀원4 |
| `infra/server/nginx/meta-gallery-{prod,dev}.conf` | `server_name` | 인프라팀 팀원3 |
| `.github/workflows/deploy-{dev,prod}.yml` | `PUBLIC_HOST`, `DUCKDNS_SUBDOMAIN`, `environment.url` | 인프라팀 팀원1 |
| `.github/pull_request_template.md` | 배포 대상 주소 | 인프라팀 팀원1 |
| `infra/server/env/{prod,dev}.env.example` | `PUBLIC_BASE_URL` | 인프라팀 팀원3 |
| `scripts/deploy/{remote-release,rollback}.sh` | `PUBLIC_HOST` | 인프라팀 팀원1 |
| `infra/terraform/outputs.tf` | `duckdns_dns_targets` 키 | 인프라팀 팀원2 |
| `docs/infra/{domain-and-https,server-layout,git-and-cicd,monitoring,aws-resources}.md` | 호스트명 표기 | 인프라팀 팀원4 |

전수 확인은 `grep -rn 'duckdns.org' . --exclude-dir=.git` 로 한다.
`docs/decisions/`는 CEO 결정 원문 기록이므로 고치지 않는다(옛 이름이 남아 있는 것이 정상이다).

## 8. 하지 않은 것

- DuckDNS 계정 생성, 토큰 발급, API 호출 — 하지 않았다(CEO 작업).
- 운영계 `metagallery`는 2026-11-13 CEO가 발급했다(비서실장 전달). 개발계 `metagallery-dev`
  등록 여부와 IPv6 칸 상태는 조회하지 않았다. **확인하지 못함.**
- DuckDNS는 무료 서비스로 SLA가 없다. 장애 시 도메인 접속이 끊기며, 그때는 고정 IP 직접 접속으로 임시 대응한다.

## 9. 변경 이력

- 2026-11-13: 최초 작성(IT본부 인프라팀 팀원4)
- 2026-11-13: CEO 발급값 반영 — 호스트명 `metagallery.duckdns.org` / `metagallery-dev.duckdns.org`,
  서브도메인 이름 `metagallery` / `metagallery-dev`(하이픈 없음)로 교체. 7절 대체 이름 규칙 재정렬과
  고칠 곳 전수 목록 확장, 1절에 IPv6 칸을 비워 두는 이유 추가.

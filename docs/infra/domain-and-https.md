# 도메인(DuckDNS)과 HTTPS(Let's Encrypt) 절차

- 날짜: 2026-11-13
- 작성 주체: 주관 IT본부 인프라팀(팀원 4) / 협조 요청: 인프라팀 팀원3(nginx), 정보보호본부 애플리케이션보안팀
- 근거 계획: `docs/plans/2026-11-13-aws-infra.md` 1-3
- 상태: **문서와 스크립트까지만.** 실제 서버가 없어 발급은 하지 않았다(아래 명령은 CEO 승인 후 서버에서 실행).

## 0. 한눈에 보기

| 항목 | 값 |
|---|---|
| 운영계 호스트명 | `metagallery.duckdns.org` |
| 개발계 호스트명 | `metagallery-dev.duckdns.org` |
| DNS | DuckDNS (무료). 두 서브도메인이 같은 Lightsail 고정 IP를 가리킨다 |
| 환경 분기 | nginx `server_name` (DNS가 아니라 nginx가 나눈다) |
| 인증서 | Let's Encrypt, certbot, **HTTP-01 (webroot)** |
| 인증서 이름 | 운영계 `meta-gallery-prod` / 개발계 `meta-gallery-dev` (환경별로 분리 발급) |
| ACME webroot | `/var/www/certbot` |
| 갱신 | certbot 패키지의 `certbot.timer` (하루 2회 시도, 만료 30일 전부터 실제 갱신) |
| 갱신 후 처리 | `--deploy-hook "systemctl reload nginx"` |
| 발급 스크립트 | `scripts/ops/issue-certificates.sh` |

환경별로 인증서를 **따로** 발급하는 이유: 한 인증서에 두 도메인을 묶으면 개발계 DNS/도메인 문제가
운영계 갱신 실패로 번진다. 분리하면 서로 영향이 없다.
`*.duckdns.org`는 Public Suffix List에 등록돼 있어 **서브도메인별 발급 한도가 독립**이다
(등록 도메인 단위 주당 50건 한도를 `duckdns.org` 전체와 나눠 쓰지 않는다).

## 1. 선행 조건 (이게 안 되면 발급은 반드시 실패한다)

- [ ] Lightsail 인스턴스 `meta-gallery-app`이 떠 있고 고정 IP `meta-gallery-ip`가 붙어 있다.
- [ ] Lightsail 방화벽에 **TCP 80과 443이 전체 공개**로 열려 있다(HTTP-01은 80번으로 검증한다).
- [ ] DuckDNS 서브도메인 2개가 그 고정 IP를 가리키고, `duckdns-update.timer`가 active다 → `infra/duckdns/README.md`
- [ ] nginx가 떠 있고, 두 `server_name`이 각각 80번에서 응답한다.
- [ ] nginx에 ACME challenge location이 있다(아래 1-1).
- [ ] `/etc/meta-gallery/certbot.env`에 `ACME_EMAIL`이 들어 있다(아래 1-2).

### 1-1. nginx에 필요한 설정 (설정 파일 담당: 인프라팀 팀원3)

운영계·개발계 **두 서버 블록 모두** 80번 쪽에 아래 location이 있어야 한다.
개발계는 Basic 인증이 걸리므로 `auth_basic off`를 빠뜨리면 검증이 401로 실패한다.

```nginx
location ^~ /.well-known/acme-challenge/ {
    root /var/www/certbot;
    default_type "text/plain";
    auth_basic off;
    allow all;
}
```

> **팀장 확인 필요**: `/var/www/certbot`은 계획 1장에 없던 경로다. 팀원4가 ACME webroot로 새로
> 정했다. 팀원3의 nginx 설정과 반드시 같아야 하므로 팀장이 한쪽으로 확정해 주기 바란다.
> 다른 경로로 정하면 `ACME_WEBROOT` 환경변수로 스크립트에 넘길 수 있다.

webroot 디렉터리 생성:

```bash
sudo install -d -o root -g www-data -m 0755 /var/www/certbot
sudo install -d -o root -g www-data -m 0755 /var/www/certbot/.well-known
sudo install -d -o root -g www-data -m 0755 /var/www/certbot/.well-known/acme-challenge
```

### 1-2. 만료 알림 이메일 등록

```bash
sudo install -d -o root -g root -m 0700 /etc/meta-gallery
sudo install -o root -g root -m 0600 /dev/null /etc/meta-gallery/certbot.env
sudo nano /etc/meta-gallery/certbot.env
```

```sh
# /etc/meta-gallery/certbot.env  (root:root 0600)
ACME_EMAIL="<만료 알림을 받을 주소>"
```

> 이메일 주소는 Let's Encrypt에 등록되는 개인정보다. 어느 주소를 쓸지는 **CEO 결정 사항**이며,
> 인프라팀이 임의로 넣지 않았다.

## 2. 발급 절차 (순서 고정: staging dry-run → 본 발급 → 자동갱신 확인)

```bash
# 0) certbot 설치 (Ubuntu 24.04 기본 저장소)
sudo apt-get update
sudo apt-get install -y certbot

# 1) 스크립트 배치
sudo install -o root -g root -m 0750 scripts/ops/issue-certificates.sh /usr/local/sbin/issue-certificates.sh
```

### 단계 1 — preflight + staging dry-run (운영 한도를 쓰지 않는다)

```bash
sudo /usr/local/sbin/issue-certificates.sh prod
```

이 명령이 하는 일:

1. root 여부, certbot·curl 설치, nginx active 확인
2. `/var/www/certbot/.well-known/acme-challenge` 존재 확인
3. `metagallery.duckdns.org`의 DNS 응답 IP와 인스턴스 공인 IP(IMDSv2 조회) 일치 확인
4. challenge 디렉터리에 probe 파일을 넣고 `http://metagallery.duckdns.org/.well-known/acme-challenge/<probe>`가
   **200**인지 외부 경로로 확인한 뒤 probe 파일을 지운다
5. `certbot certonly --webroot --dry-run` (Let's Encrypt **staging**) 실행

여기서 멈추고 성공 메시지를 확인한다. `--confirm`을 주지 않았으므로 본 발급은 하지 않는다.

```bash
sudo /usr/local/sbin/issue-certificates.sh dev        # 개발계도 같이 dry-run
```

### 단계 2 — 본 발급 (dry-run이 통과한 뒤에만)

```bash
sudo /usr/local/sbin/issue-certificates.sh prod --confirm
sudo /usr/local/sbin/issue-certificates.sh dev  --confirm
# 두 환경을 연달아 하려면: sudo /usr/local/sbin/issue-certificates.sh all --confirm
```

실행되는 명령(스크립트 내부, 운영계 예시):

```bash
certbot certonly \
  --webroot --webroot-path /var/www/certbot \
  --domain metagallery.duckdns.org \
  --cert-name meta-gallery-prod \
  --email "$ACME_EMAIL" \
  --agree-tos --no-eff-email \
  --non-interactive \
  --keep-until-expiring \
  --deploy-hook "systemctl reload nginx"
```

생성 경로:

| 환경 | fullchain | privkey |
|---|---|---|
| 운영계 | `/etc/letsencrypt/live/meta-gallery-prod/fullchain.pem` | `/etc/letsencrypt/live/meta-gallery-prod/privkey.pem` |
| 개발계 | `/etc/letsencrypt/live/meta-gallery-dev/fullchain.pem` | `/etc/letsencrypt/live/meta-gallery-dev/privkey.pem` |

nginx의 `ssl_certificate` / `ssl_certificate_key`가 위 경로와 같아야 한다(팀원3 설정 확인).

### 단계 3 — 자동갱신 확인

```bash
sudo /usr/local/sbin/issue-certificates.sh prod --verify-only
sudo /usr/local/sbin/issue-certificates.sh dev  --verify-only
```

수동으로 확인하려면:

```bash
sudo certbot certificates                         # 인증서 2개와 만료일
systemctl is-enabled certbot.timer                # enabled 여야 한다
systemctl list-timers certbot.timer --no-pager    # 다음 실행 시각
sudo certbot renew --dry-run                      # 갱신 리허설(staging)
grep -n renew_hook /etc/letsencrypt/renewal/meta-gallery-prod.conf   # deploy-hook 등록 확인
grep -n renew_hook /etc/letsencrypt/renewal/meta-gallery-dev.conf
```

`certbot.timer`가 없거나 disabled면:

```bash
sudo systemctl enable --now certbot.timer
```

## 3. HTTP → HTTPS 전환 순서

1. 인증서가 **없는 상태에서** nginx에 `ssl_certificate`를 먼저 넣으면 nginx가 기동에 실패한다.
   따라서 순서는 **80번만 있는 설정으로 기동 → 인증서 발급 → 443 블록 추가 → `nginx -t` → reload**다.
2. 443 블록을 넣은 뒤 `sudo nginx -t`가 통과해야 reload 한다.
3. 전환 후 80번은 `return 301 https://$host$request_uri;`로 넘긴다(단, `^~ /.well-known/acme-challenge/`는
   리다이렉트 **앞**에 두어 갱신이 계속 되도록 한다).
4. HSTS 적용 여부와 max-age는 **정보보호본부 애플리케이션보안팀 검토 사항**이다(잘못 켜면 되돌리기 어렵다).

## 4. 실패 대응

| 증상 | 원인/대응 |
|---|---|
| preflight에서 `HTTP 404` | nginx에 acme-challenge location이 없다 → 1-1 적용 후 reload |
| preflight에서 `HTTP 401` | 개발계 Basic 인증이 challenge 경로에도 걸렸다 → `auth_basic off;` 추가 |
| preflight에서 공인 IP 불일치 | DuckDNS가 다른 IP를 가리킨다 → `sudo duckdns-update.sh` 1회 실행 후 재시도 |
| dry-run 실패 | **본 발급을 시도하지 말 것.** 원인 해결 후 dry-run부터 다시 한다 |
| `too many certificates already issued` | 운영 한도 초과. 동일 도메인 세트 주당 5회. 최소 1주 대기하거나 기존 인증서를 재사용한다 |
| 갱신 실패 알림 | `journalctl -u certbot.service -n 50`, 80번 도달성과 webroot 권한 확인 |
| 인증서는 갱신됐는데 브라우저는 옛 인증서 | deploy-hook이 안 걸렸다 → `renew_hook` 확인 후 `systemctl reload nginx` |

## 5. 하지 않은 것 / 확인하지 못한 것

- certbot 실행, 인증서 발급, Let's Encrypt API 호출 — 하지 않았다(대상 서버가 없다).
- 운영계 서브도메인 `metagallery`는 2026-11-13 CEO가 DuckDNS에 발급했다. 개발계 `metagallery-dev` 등록 여부는 **확인하지 못함**(외부 조회를 하지 않았다).
  선점 시 대체 이름 규칙은 `infra/duckdns/README.md` 7절.
- 위 명령들은 서버에서 실제로 실행해 본 것이 아니다. 문법 검사(`bash -n`, `shellcheck`)까지만 했다.

## 변경 이력

- 2026-11-13: 최초 작성(IT본부 인프라팀 팀원4)
- 2026-11-13: CEO 발급값에 맞춰 DuckDNS 호스트명 교체 — 하이픈 있는 옛 이름(`meta-gallery` / `meta-gallery-dev` + `.duckdns.org`)에서 `metagallery.duckdns.org` / `metagallery-dev.duckdns.org`로, DuckDNS 서브도메인 이름도 `metagallery` / `metagallery-dev`로 바꿨다. 인스턴스·고정 IP 이름, S3 버킷, 서버 경로, systemd 유닛, nginx 설정 파일명, certbot `--cert-name`, DB·롤 이름은 바꾸지 않았다. 근거: `docs/plans/2026-11-13-aws-infra.md` 1-3 변경 사유.

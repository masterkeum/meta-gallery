# git 저장소와 배포 파이프라인 (CI/CD)

- 날짜: 2026-11-13
- 주관: IT본부 인프라팀 (팀원 1)
- 기준 계획: `docs/plans/2026-11-13-aws-infra.md` (1-2 서버 경로/호스트명, 1-6 git·배포)
- 상태: **설계·코드까지만.** GitHub 원격 저장소는 만들지 않았고, 실제 배포도 하지 않았다.

---

## 1. 이 문서가 다루는 범위

| 산출물 | 역할 |
|---|---|
| `.gitignore` | 빌드 산출물·비밀값·키·Terraform 상태 파일을 추적에서 제외 |
| `.gitattributes` | 저장소 줄바꿈을 LF로 통일(Ubuntu에서 셸 스크립트가 깨지지 않게) |
| `.github/workflows/ci.yml` | PR·push 공통 검사 (배포 없음) |
| `.github/workflows/deploy-dev.yml` | `dev` 브랜치 → 개발계 배포 |
| `.github/workflows/deploy-prod.yml` | `main` 브랜치 → 운영계 배포 |
| `.github/pull_request_template.md` | PR 체크리스트 |
| `scripts/deploy/remote-release.sh` | **서버 안에서** 실행: 릴리스 설치·심링크 교체·헬스체크·자동 롤백 |
| `scripts/deploy/rollback.sh` | **서버 안에서** 실행: 이전(또는 지정) 릴리스로 되돌리기 |
| `scripts/ci/secret-scan.py` | 평문 비밀값 검사기(CI와 로컬에서 같은 코드를 쓴다) |
| `scripts/ci/test-secret-scan.py` | 검사기 회귀 테스트 |
| `scripts/ci/testdata/` | 회귀 테스트 표본(반드시 탐지 19건 + 오탐 금지 표본 + 알려진 한계 표본) |

관련 문서: `docs/infra/aws-resources.md`(AWS 자원), `docs/infra/server-layout.md`(서버 내부 구성),
`docs/infra/domain-and-https.md`(도메인·인증서), `docs/infra/monitoring.md`(모니터링).

---

## 2. 브랜치 전략

```
feature/<주제>  ──PR──▶  dev  ──PR──▶  main
                          │              │
                          ▼              ▼
                   개발계 자동 배포    운영계 배포(승인 게이트)
          metagallery-dev.duckdns.org   metagallery.duckdns.org
```

- `main`: 운영계. 항상 배포 가능한 상태로 둔다.
- `dev`: 개발계. 기능 통합 지점.
- `feature/*`: 작업 브랜치. `dev`로 PR을 올린다.
- 두 브랜치 모두 **직접 push 금지, PR 필수**로 보호한다(설정 절차는 5장).
- 릴리스 식별자는 **커밋 SHA**다. 태그를 따로 쓰지 않는다(목업 단계라 불필요).

---

## 3. 워크플로 3개

### 3-1. `ci.yml` — PR·push 공통 검사

시크릿을 전혀 쓰지 않는다(`permissions: contents: read`). 포크 PR에서 비밀값이 노출될 경로가 없다.

| 잡 | 검사 내용 |
|---|---|
| `build` | `python3 scripts/build-standalone.py` 실행 성공, `dist/meta-gallery.html`이 비어 있지 않고 20,000 bytes 이상, 필수 구조 문자열(`<!doctype html>`, viewport 등) 존재, three.js **r128** CDN 참조 유지(다른 버전이 섞이면 실패), 산출물 artifact 업로드(7일 보관) |
| `shell-lint` | 저장소의 모든 `*.sh`에 `bash -n` + `shellcheck` |
| `terraform-fmt` | `terraform fmt -check -recursive infra/terraform` (`init`/`plan`/`apply`는 돌리지 않는다) |
| `secret-scan` | 워크플로 YAML 파싱 확인 + **검사기 회귀 테스트** + 평문 비밀값 패턴 검사 |

**three.js 버전 고정 검사**는 README.md에 적은 규칙(r128에 없는 API 금지)을 CI에서 강제하기 위한 것이다.
기대 문자열은 `https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js` 하나다.

#### 평문 비밀값 검사기

검사기는 `ci.yml` 인라인이 아니라 **별도 파일로 분리**돼 있다.

| 파일 | 역할 |
|---|---|
| `scripts/ci/secret-scan.py` | 검사기 본체 |
| `scripts/ci/test-secret-scan.py` | 회귀 테스트(검사기가 제대로 잡는지 검사) |
| `scripts/ci/testdata/` | 가짜 비밀값 표본과 자리표시자 표본 |

로컬에서 그대로 돌릴 수 있다.

```bash
python3 scripts/ci/secret-scan.py                 # 저장소 전체 검사
python3 scripts/ci/secret-scan.py <파일>...        # 특정 파일만 검사
python3 scripts/ci/test-secret-scan.py            # 검사기 회귀 테스트
```

**잡는 것**: AWS 액세스 키 ID(`AKIA`/`ASIA`), 개인키 블록(`-----BEGIN ... PRIVATE KEY-----`),
AWS 시크릿 키 할당, DB 접속 문자열 속 비밀번호, 키 이름에 `password`/`secret`/`token`/`api_key`
등이 든 직접 할당, 공인 IP 하드코딩.

**넘기는 것(면제)**: 면제는 **줄이나 파일이 아니라 "값"에만** 적용하고, 두 가지 방식만 쓴다.

1. **완전일치** — 값 전체가 `<...>` · `__REPLACE_WITH_...__` · `${VAR}` · `${{ secrets.X }}` ·
   `CHANGE_ME` 같은 자리표시자이거나, `yes`/`no`/`scram-sha-256` 같은 설정값일 때.
2. **잔여 런 검사** — 값에 자리표시자·포맷(`%s`)·마스크(`***`, `REDACTED`) 토큰이 있을 때,
   그 토큰을 **지운 뒤 영숫자가 8자 이상 연속으로 남으면 면제하지 않는다.**

키 이름 예외는 앵커로 좁혔다(`^NOPASSWD:` 같은 sudoers 태그, `^password_encryption=`).
DB 접속 문자열의 비밀번호는 포맷·마스크 템플릿으로 쓰이는 일이 없어 **완전일치만** 면제한다.

> **왜 이렇게 바꿨나 (2026-11-13)**
> 처음 구현은 자리표시자 패턴이 **주석에만** 있어도 그 줄 전체를 면제하고, `.example`
> 파일은 통째로 건너뛰었다. 그래서 `DUCKDNS_TOKEN=<진짜값> # ${HOME}에 둔다` 나
> `.example`에 실수로 붙여넣은 실제 비밀번호가 CI를 통과했다. 팀장 검수에서 가짜
> 비밀값 9건 중 **3건만 탐지**된 것이 확인돼, 면제를 값 단위로 바꾸고 `.example`을
> 검사 대상에 넣었다.
>
> 그런데 그 과정에서 오탐을 없애려 넣은 값 예외("값 안에 `***`/`REDACTED`/`%s`가 있으면
> 면제")가 다시 구멍이 됐다. 진짜 비밀값에 가림 문자만 덧붙이면
> (`DB_PASSWORD=<실제값>***`, `API_TOKEN=REDACTED_BUT_REAL_<실제값>`) 그대로 통과했고,
> 2차 검수에서 심은 10건이 **전부 미탐지**로 확인됐다. 그래서 면제를 위의 "완전일치 +
> 잔여 런 검사" 두 가지로만 제한했다. 덧붙여 값 추출이 `#`에서 끊겨 비밀번호에 `#`가
> 든 값을 아예 매치하지 못하던 문제, `/`로 시작하는 base64 비밀값이 경로로 오인되던
> 문제도 함께 고쳤다. 사례는 모두 `scripts/ci/testdata/`에 회귀 테스트로 박아 뒀다.

**한계** (사람 검토를 대체하지 않는다. 아래 사례는 `scripts/ci/testdata/known-limits.txt`에
표본으로 고정해 뒀고, 탐지되기 시작하면 회귀 테스트가 실패해 이 문서 갱신을 요구한다):
- **영숫자 8자 하한**이 있다. 값이 8자 미만(`SHORT_TOKEN=Ab3xY9z`)이거나, 토큰을 지운
  잔여 런이 8자 미만(`TOKEN=abc***def`)이면 놓친다.
  하한을 내려 보니 **7자에서 팀원4의 정상 로그·URL 템플릿 2건이 오탐**으로 바뀌었다
  (`infra/duckdns/duckdns-update.sh`의 `domains=%s&token=%s`, `***REDACTED***&ip=...`).
  `verbose`·`domains`가 7자라서다. 그래서 8자를 유지한다.
- 값이 **전부 소문자이고 `+`가 없는 경로 꼴**이면 비밀값이 아니라고 본다
  (`DB_PASSWORD=/abc/defghijk/lmnop`). 대문자나 `+`가 섞이면 잡는다.
- 값에 **백틱**이 들어 있으면 거기서 끊긴다. 이 저장소는 문서가 많고, 산문에서 예시를
  인라인 코드로 적으면 값이 닫는 백틱을 넘어 한국어 문장까지 삼켜 오탐이 났다.
  백틱은 마크다운 경계이고 비밀번호에 쓰이는 일이 드물어 감수했다
  (주석 기호 `#`은 비밀번호에 흔히 쓰이므로 **빼지 않았다**).
- 알려진 패턴만 본다. 엔트로피 기반 탐지는 하지 않는다.
- 검사에서 빠지는 파일은 **검사기 자신(`scripts/ci/secret-scan.py`)** 하나뿐이다.
  패턴 문자열을 품고 있어서다. `ci.yml`과 `.example` 파일은 모두 검사한다.
- `scripts/ci/testdata/`는 저장소 전체 검사에서만 건너뛴다(일부러 가짜 비밀값을 담은
  표본이다). 회귀 테스트는 그 경로를 인자로 직접 넘겨 검사한다.

### 3-2. `deploy-dev.yml` / `deploy-prod.yml` — 배포

두 파일의 구조는 같고 환경값만 다르다.

| 항목 | `deploy-dev.yml` | `deploy-prod.yml` |
|---|---|---|
| 작동 조건 | `dev` push, 수동 실행 | `main` push, 수동 실행 |
| GitHub Environment | `dev` | `prod` (수동 승인 전제) |
| 대상 호스트 | `metagallery-dev.duckdns.org` | `metagallery.duckdns.org` |
| 설치 경로 | `/srv/meta-gallery/dev/releases/<sha>/` | `/srv/meta-gallery/prod/releases/<sha>/` |
| 릴리스 보관 권고 | 5개 | 10개 |

배포 단계 순서:

1. `guard` 잡 — 브랜치가 기대값(`refs/heads/dev` 또는 `refs/heads/main`)인지 확인. 아니면 즉시 실패.
2. 빌드 — `build-standalone.py` 실행 후 크기·r128 참조 검증.
3. 시크릿 등록 확인 — `LIGHTSAIL_HOST`/`LIGHTSAIL_SSH_USER`/`LIGHTSAIL_SSH_KEY`가 비어 있으면 친절한 메시지로 실패(값은 출력하지 않는다).
4. SSH 준비 — 키를 `$RUNNER_TEMP`에 `0600`으로 쓰고 `known_hosts` 준비.
5. 업로드 — `scp`로 `/tmp/meta-gallery-deploy-<sha>/`에 산출물 + 배포 스크립트 2개.
6. 릴리스 전환 — 서버에서 `remote-release.sh` 실행(설치 → 심링크 교체 → 확인 → `/healthz` → 실패 시 자동 롤백).
7. 실패 시 — `if: failure()`로 `rollback.sh` 호출(안전망).
8. DuckDNS 갱신 — `DUCKDNS_TOKEN`이 등록된 경우에만. 참고용이며 실패해도 배포를 깨지 않는다.
9. 외부 접속 확인 — `https://<host>/healthz`. **참고용**(인증서 미발급·개발계 Basic 인증 때문에 실패할 수 있다).
10. 요약 — 환경·커밋·릴리스 경로·롤백 명령을 작업 요약에 남긴다.

---

## 4. 배포와 롤백이 서버에서 실제로 하는 일

### 4-1. 릴리스 전환 (`remote-release.sh`)

```
/srv/meta-gallery/<env>/
  releases/<sha>/index.html         ← 배포 단위(불변). nginx가 index로 찾는다
  releases/<sha>/meta-gallery.html  ← 같은 내용(nginx index 두 번째 후보)
  releases/<sha>/RELEASE.json       ← 환경·sha·배포시각·배포자·sha256 (비밀값 없음)
  current -> releases/<sha>         ← 이 심링크만 바꿔서 전환한다
  shared/previous-release           ← 직전 sha. 롤백 대상 포인터
```

```bash
bash remote-release.sh --env dev --sha <git-sha> --artifact <업로드된 html 경로>
```

- 전환은 `ln -s` + `mv -T`(rename 한 번)로 **중간 상태 없이** 바뀐다. 포인터만 바꾸므로 되돌릴 수 있다.
- 전환 직후 `current`가 가리키는 실제 파일의 sha256을 업로드한 산출물과 비교한다.
  `/healthz`는 nginx가 고정 문자열을 반환하는 엔드포인트라 "nginx가 살아 있다"만 증명하기 때문에,
  "올바른 릴리스가 연결됐다"는 이 sha256 비교로 확인한다.
- `/healthz`는 3초 간격 최대 10회 재시도한다. 서버 내부에서 `Host` 헤더를 붙여 루프백으로 호출하므로
  DNS·인증서 상태와 무관하게 판정한다.
- **같은 SHA를 다시 배포하면** 이미 설치된 파일을 덮어쓰지 않고 심링크만 전환한다(`--reinstall`로 강제 재설치).
- **이 스크립트는 아무것도 삭제하지 않는다.** 릴리스가 권고 개수를 넘으면 경고만 남긴다(7장).

### 4-2. 자동 롤백

`/healthz`가 10회 연속 실패하면 스크립트가 스스로 직전 릴리스로 심링크를 되돌리고, nginx를 reload한 뒤,
0이 아닌 코드로 끝난다. **실패한 릴리스 디렉터리는 지우지 않고 남겨 둔다**(원인 조사용).

직전 릴리스가 없으면(최초 배포) 되돌릴 대상이 없으므로 그 사실을 알리고 실패한다. 이때는 수동 확인이 필요하다.

### 4-3. 수동 롤백 (`rollback.sh`)

서버에 SSH로 들어가서 실행한다.

```bash
cd /srv/meta-gallery/<env>/releases/<아무 sha>   # 또는 스크립트를 둔 경로
bash rollback.sh --env prod --list         # 설치된 릴리스와 현재 링크 확인
bash rollback.sh --env prod                # 직전 릴리스로 되돌리기
bash rollback.sh --env prod --to 0a1b2c3   # 특정 릴리스로 되돌리기
```

- 되돌리기 전 SHA를 `shared/previous-release`에 남기므로 **다시 앞으로 되돌릴 수도 있다**.
- 대상 릴리스에 `index.html`이 없거나 비어 있으면 거부한다.
- 이미 그 릴리스를 가리키고 있으면 아무것도 하지 않고 끝난다(멱등).
- 역시 아무것도 삭제하지 않는다.

> 배포 스크립트는 매 배포 때 `/tmp/meta-gallery-deploy-<sha>/`로 함께 업로드되므로,
> 서버에 SSH만 되면 항상 최신 `rollback.sh`를 쓸 수 있다.

### 4-4. 파이프라인이 아예 안 돌 때 (최후 수단)

GitHub Actions가 막혔는데 되돌려야 하면, 서버에서 심링크를 직접 바꾼다.

```bash
ls -l /srv/meta-gallery/prod/current                 # 현재 가리키는 곳
ls -1 /srv/meta-gallery/prod/releases                # 되돌릴 후보
ln -s /srv/meta-gallery/prod/releases/<sha> /srv/meta-gallery/prod/.current.manual
mv -T /srv/meta-gallery/prod/.current.manual /srv/meta-gallery/prod/current
sudo systemctl reload nginx
curl -sS -o /dev/null -w '%{http_code}\n' -H 'Host: metagallery.duckdns.org' http://127.0.0.1/healthz
```

---

## 5. GitHub 저장소 만들기 (CEO 작업)

> 인프라팀은 외부 서비스 가입·저장소 생성을 하지 않는다. 아래는 CEO가 그대로 따라 하는 순서다.
> 1~3번은 **CEO 결정이 먼저 필요**하다(`docs/plans/2026-11-13-aws-infra.md` 5장 3번).

### 5-1. 결정할 것

1. 어느 계정/조직에 만들까 (개인 계정 `masterkeum` / 새 조직)
2. 공개(public) / 비공개(private) — **인프라팀 권고: 비공개.** 배포 설정·서버 경로가 드러나기 때문이다.
3. 저장소 이름 — 권고: `meta-gallery`

### 5-2. 로컬 저장소 (인프라팀이 이미 준비)

인프라팀이 `git init -b main` → 최초 커밋 → `dev` 브랜치까지 만들어 뒀다 (2026-11-13 실행).
**원격 연결과 push는 하지 않았다.**

실행 결과:

| 확인 항목 | 결과 |
|---|---|
| 기본 브랜치 | `main` (`git init -b main`) |
| 커밋 | 1개 — `AWS 배포 환경 설계·스크립트 최초 커밋` |
| 브랜치 | `main`, `dev` |
| `git status` | clean (추적되지 않은 파일 없음) |
| 추적 파일 | 89개 |
| 원격 | 없음 (`git remote -v` 출력 없음) |
| 무시된 것 | `dist/`, `scripts/ci/__pycache__/` 2개뿐 |

추적 파일에 `dist/` · `*.env` · `*.pem` · `*.tfstate` · `__pycache__` · `.DS_Store`는
**0건**이고, 자리표시자용 `*.example` 5개는 의도대로 추적된다.

#### `.gitignore` 실물 확인 (`git check-ignore`)

회귀 테스트 표본이 `.gitignore`에 걸려 커밋에서 빠지면 CI가 "표본 없음"으로 깨진다.
그래서 `git init` 직후 실물로 확인했다. **표본 6개 모두 추적 대상이다.**

```bash
# 종료코드 1 = 무시되지 않음(추적 대상)
git check-ignore -q scripts/ci/testdata/<파일>
```

| 표본 | 결과 |
|---|---|
| `fake-secrets-env.txt` | 추적됨 |
| `fake-secrets-masked.txt` | 추적됨 |
| `fake-public-ip.txt` | 추적됨 |
| `known-limits.txt` | 추적됨 |
| `fake-secrets.env.example` | 추적됨 (`.gitignore:16:!*.env.example` 부정 패턴이 되살림) |
| `clean-placeholders.env.example` | 추적됨 (같은 부정 패턴) |

> **주의**: `git check-ignore -v`는 **부정 패턴(`!`)에 걸려도 종료코드 0**을 돌려준다.
> "출력이 있으면 무시됨"으로 읽으면 안 된다. 판정은 `-v` 없이 **종료코드로** 해야 한다
> (1 = 무시되지 않음). 표본 이름을 `*.env`에서 `*.txt`로 바꾼 이유도 이것이다.

반대로 무시돼야 하는 것들도 실물로 확인했다.

| 경로 | 매칭 패턴 |
|---|---|
| `dist/meta-gallery.html` | `.gitignore:7:dist/` |
| `scripts/ci/__pycache__/*.pyc` | `.gitignore:49:__pycache__/` |
| `infra/server/env/prod.env` | `.gitignore:15:*.env` |
| `id_rsa.pem` | `.gitignore:26:id_rsa.*` |
| `infra/terraform/terraform.tfstate` | `.gitignore:35:terraform.tfstate*` |
| `.DS_Store` | `.gitignore:57:.DS_Store` |

#### 원격 저장소 연결 (CEO가 원격을 만든 뒤)

아래는 CEO가 원격을 만든 뒤 실행할 명령이다. 인프라팀은 실행하지 않았다.

```bash
cd ~/meta-gallery
git remote add origin git@github.com:<계정>/meta-gallery.git
git push -u origin main
git push -u origin dev
```

### 5-3. 브랜치 보호 규칙

GitHub 웹 → Settings → Branches → Add branch ruleset. `main`과 `dev` 각각에:

- [ ] Require a pull request before merging (직접 push 금지)
- [ ] Require status checks to pass → `build`, `shell-lint`, `terraform-fmt`, `secret-scan` 선택
      (**이름은 `ci.yml`의 잡 이름이다. 워크플로가 한 번 돌아야 목록에 나타난다.**)
- [ ] Require branches to be up to date before merging
- [ ] Do not allow bypassing the above settings (1인 운영이면 이건 빼도 된다)

> 운영계 배포 전에 CI 통과를 보장하는 것은 이 브랜치 보호 규칙이다.
> `deploy-prod.yml`은 CI 결과를 직접 조회하지 않는다.

### 5-4. Environments와 시크릿 등록

GitHub 웹 → Settings → Environments → `dev`, `prod` **두 개**를 만든다.
그다음 각 Environment의 "Environment secrets"에 아래를 넣는다.
(저장소 전체 시크릿이 아니라 **Environment 시크릿**이어야 환경이 분리된다.)

| 이름 | 값 | dev | prod | 비고 |
|---|---|---|---|---|
| `LIGHTSAIL_HOST` | 고정 IP 또는 접속용 호스트명 | 필수 | 필수 | 두 환경이 같은 인스턴스를 쓰므로 값이 같다 |
| `LIGHTSAIL_SSH_USER` | 배포 계정 이름 (`deploy`) | 필수 | 필수 | 계획 1-2의 배포 계정 |
| `LIGHTSAIL_SSH_KEY` | 배포용 SSH **개인키 전문** | 필수 | 필수 | `-----BEGIN ...` 줄부터 끝 줄까지 그대로 붙인다 |
| `LIGHTSAIL_SSH_HOST_KEY` | 서버 호스트 공개키 1줄 | 권고 | 권고 | 없으면 최초 접속 키를 그냥 믿는다(중간자 공격 위험) |
| `DUCKDNS_TOKEN` | DuckDNS 토큰 | 선택 | 선택 | 없으면 갱신 단계를 건너뛴다. 서버 timer가 5분마다 갱신한다 |

`LIGHTSAIL_SSH_HOST_KEY` 값 얻는 방법(서버가 뜬 다음, CEO의 PC에서):

```bash
ssh-keyscan -t ed25519 <서버_IP>
```

출력된 한 줄을 그대로 시크릿에 넣는다.

> SSH 키 생성·보관 방식과 `deploy` 계정 권한 범위는 **정보보호본부 애플리케이션보안팀 검토 대상**이다
> (`docs/plans/2026-11-13-aws-infra.md` 3-2). 장기 AWS 액세스 키 대신 OIDC 역할을 쓰라는 권고도 함께 있다.

### 5-5. 운영계 수동 승인 게이트 — **CEO 결정 대기**

`deploy-prod.yml`은 Environment `prod`에 수동 승인이 걸리는 전제로 작성했다.
하지만 **승인자 지정은 GitHub 웹에서만 할 수 있고, 둘지 여부는 아직 결정되지 않았다**
(`docs/plans/2026-11-13-aws-infra.md` 5장 4번. 인프라팀 권고: 둔다).

둘 경우: Settings → Environments → `prod` → Deployment protection rules →
"Required reviewers" 체크 후 CEO 계정 추가.

**지정하지 않으면 `main`에 머지되는 즉시 운영계로 바로 배포된다.** 이 점을 결정 전에 유의해야 한다.

---

## 6. 처음 배포하기 전에 서버에 있어야 하는 것

배포 워크플로는 서버가 이미 준비됐다고 가정한다. 준비는 `infra/server/scripts/provision.sh`가 한다
(`docs/infra/server-layout.md` 참고).

- [ ] `/srv/meta-gallery/{prod,dev}` 디렉터리와 `deploy` 계정 소유권
- [ ] nginx 설치, `meta-gallery-{prod,dev}.conf` 적용, `/healthz` 200 응답
- [ ] `deploy` 계정에 `systemctl reload nginx` sudoers 규칙 (없으면 경고만 남고 배포는 계속된다)
- [ ] `deploy` 계정 `~/.ssh/authorized_keys`에 배포용 공개키
- [ ] DuckDNS 서브도메인 2개가 고정 IP를 가리킴

첫 배포는 `dev`로 먼저 한다. 수동 실행(Actions → Deploy (dev) → Run workflow)으로 시험할 수 있다.

---

## 7. 릴리스 보관과 정리

- 산출물이 HTML 한 개(약 70KB)라 릴리스가 쌓여도 40GB 디스크에는 사실상 영향이 없다.
- 그래서 **배포 스크립트는 오래된 릴리스를 삭제하지 않는다.** 권고 개수(dev 5 / prod 10)를 넘으면 경고만 남긴다.
  인프라팀 원칙상 되돌리기 어려운 삭제 명령을 자동 실행하지 않기 때문이다.
- 정리가 필요해지면 **사람이 확인하면서** 아래 순서로 한다.

```bash
# 1) 현재 쓰는 릴리스를 먼저 확인한다 (이걸 지우면 서비스가 죽는다)
ls -l /srv/meta-gallery/prod/current
cat  /srv/meta-gallery/prod/shared/previous-release   # 롤백 대상도 남겨야 한다

# 2) 지울 후보를 눈으로 본다 (아직 지우지 않는다)
ls -1t /srv/meta-gallery/prod/releases | tail -n +11

# 3) 위 목록에 current 와 previous-release 가 없는지 확인한 뒤, 하나씩 지운다
#    (한 번에 여러 개를 지우거나 rm -rf 를 스크립트에 넣지 않는다)
rm -r /srv/meta-gallery/prod/releases/<확인한 sha>
```

- `/tmp/meta-gallery-deploy-<sha>/` 업로드 임시 디렉터리는 Ubuntu의 `systemd-tmpfiles`가 알아서 정리한다(기본 10일).

---

## 8. 알려진 제약 / 확인하지 못한 것

- **GitHub 원격 저장소가 없어 워크플로를 실제로 실행해 본 적이 없다.** YAML 파싱과 셸 블록 문법까지만 확인했다.
  처음 돌릴 때 액션 버전·러너 환경 문제로 손볼 가능성이 있다.
- **배포 스크립트의 정상 경로(happy path)를 실행해 보지 못했다.** `/srv` 쓰기 권한, `mv -T`(GNU coreutils),
  `systemctl`, nginx가 모두 필요해 Ubuntu 서버에서만 확인할 수 있다. 로컬에서는 인자·산출물 검증 경로와
  `bash -n`·`shellcheck`까지만 확인했다. → 서버가 준비되면 `dev`에서 먼저 검증해야 한다.
- 배포 스크립트는 **Ubuntu 기준**이다. `mv -T`는 macOS `mv`에 없어 로컬 맥에서는 그대로 돌지 않는다.
- `deploy-prod.yml`은 "이 커밋이 CI를 통과했는지"를 직접 조회하지 않는다. 브랜치 보호 규칙에 의존한다(5-3).
- `ci.yml`의 액션은 버전 태그(`@v4`, `@v5`, `@v3`)로 고정했다. **커밋 SHA 고정이 더 안전**하며,
  이는 애플리케이션보안팀 검토 사항이다.
- 평문 비밀값 검사기의 한계는 3-1에 적었다. 사람 검토를 대체하지 않는다.
  회귀 테스트(`python3 scripts/ci/test-secret-scan.py`)는 로컬에서 통과를 확인했지만,
  **GitHub Actions 러너에서 실제로 돌려 본 적은 없다**(원격 저장소가 없다).
- 배포 산출물이 정적 HTML 하나뿐이라, 향후 백엔드 API가 생기면 `deploy-*.yml`에
  systemd 재시작·마이그레이션 단계를 더해야 한다(백엔드팀 협조 사항).

---

## 9. 다른 팀 협조가 필요한 것

- **정보보호본부 애플리케이션보안팀**: SSH 키 생성·보관, `LIGHTSAIL_SSH_HOST_KEY` 등록 권고,
  액션 SHA 고정, 포크 PR 시크릿 차단, OIDC 역할 전환, `deploy` 계정 sudoers 최소 권한.
- **IT본부 백엔드팀**: 백엔드가 생기면 배포 단계에 서비스 재시작·DB 마이그레이션을 어떤 순서로 넣을지,
  무중단 전환이 필요한지.
- **CEO 결정**: 저장소 계정·공개 범위(5-1), 운영계 수동 승인 게이트(5-5).

---

## 변경 이력

- 2026-11-13: 최초 작성(IT본부 인프라팀 팀원 1). 계획서 2장 항목 1 산출물.
- 2026-11-13: 팀장 검수 보완. 평문 비밀값 검사기를 `ci.yml` 인라인에서
  `scripts/ci/secret-scan.py`로 분리하고, 면제를 줄·파일 단위에서 **값 단위**로 바꿨다.
  `.example` 파일과 `ci.yml`을 검사 대상에 포함시키고, 회귀 테스트
  (`scripts/ci/test-secret-scan.py` + `scripts/ci/testdata/`)를 추가했다.
  배경: 가짜 비밀값 9건 중 3건만 탐지되던 결함(3-1의 "왜 이렇게 바꿨나" 참고).
- 2026-11-13: 팀장 2차 검수 보완. 값 예외가 `search()`라 진짜 비밀값에 가림·포맷 문자만
  덧붙이면 통과하던 구멍을 막았다(면제를 "완전일치 + 잔여 런 검사"로 제한).
  값 추출의 `#` 절단, 경로로 위장한 base64 비밀값, 꺾쇠 자리표시자 뒤에 붙인 비밀값도
  함께 고쳤다. `known-limits.txt`로 남은 한계를 고정했다.
- 2026-11-13: 계획서 항목 5 수행. `git init -b main` → 최초 커밋 → `dev` 브랜치 생성.
  원격 연결·push는 하지 않았다. `git check-ignore` 실물 확인 결과를 5-2에 적었다.
- 2026-11-13: CEO 발급값에 맞춰 DuckDNS 호스트명 교체 — 하이픈 있는 옛 이름(`meta-gallery` / `meta-gallery-dev` + `.duckdns.org`)에서 `metagallery.duckdns.org` / `metagallery-dev.duckdns.org`로, DuckDNS 서브도메인 이름도 `metagallery` / `metagallery-dev`로 바꿨다. 인스턴스·고정 IP 이름, S3 버킷, 서버 경로, systemd 유닛, nginx 설정 파일명, certbot `--cert-name`, DB·롤 이름은 바꾸지 않았다. 근거: `docs/plans/2026-11-13-aws-infra.md` 1-3 변경 사유.

# CI/CD 워크플로 정의

이 폴더의 YAML 3개는 **실제로 쓰는 GitHub Actions 워크플로 정의**다.
운영 저장소에서는 `.github/workflows/` 에 있고, 이 공개 저장소에서는 `docs/ci/` 에 둔다.

## 왜 `.github/workflows/` 가 아닌가

두 가지 이유다.

1. **이 공개 저장소에서 Actions가 돌 이유가 없다.** `deploy-dev.yml`·`deploy-prod.yml` 은
   서버 SSH 시크릿을 요구한다. 공개 저장소에는 그 시크릿이 없고 넣어서도 안 되므로,
   `.github/workflows/` 에 두면 push할 때마다 실패한 실행만 쌓인다.
2. 공개 저장소는 **읽히는 것이 목적**이다. 경로가 달라도 내용은 그대로이고,
   동작 방식은 [README 8장](../../README.md#8-배포)에 설명돼 있다.

## 파일

| 파일 | 트리거 | 하는 일 |
|---|---|---|
| `ci.yml` | PR·push 공통 | 빌드 성공·산출물 검증·three.js 버전 고정 확인, shellcheck, `terraform fmt -check`, 평문 비밀값 검사 |
| `deploy-dev.yml` | `dev` push | 빌드 → SSH 업로드 → `current` 심링크 교체 → `/healthz` 확인 → 실패 시 자동 롤백 |
| `deploy-prod.yml` | `main` push | 위와 동일 + 운영계 대상 |

## 실제로 쓰려면

`.github/workflows/` 로 옮기고 GitHub Environments `dev`·`prod` 에 시크릿을 등록한다.
필요한 시크릿 목록과 등록 절차는 [`docs/infra/git-and-cicd.md`](../infra/git-and-cicd.md) 에 있다.

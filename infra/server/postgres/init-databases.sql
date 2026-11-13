-- =============================================================================
-- meta-gallery PostgreSQL 16 초기화 — DB 2개 / 롤 2개 환경 분리
--   실행    : sudo runuser -u postgres -- psql -f /path/init-databases.sql
--             (provision.sh가 대신 실행한다)
--   멱등성  : 여러 번 실행해도 안전하다(존재 여부를 확인하고 만든다).
--
-- !! 이 파일에는 비밀번호를 쓰지 않는다. 롤은 비밀번호 없이 만들고,
--    provision.sh가 난수 비밀번호를 생성해 stdin(heredoc)으로만 ALTER ROLE 한다.
--    (커맨드라인·로그·저장소에 평문 비밀번호가 남지 않게)
--
-- 환경 분리 원칙(계획서 1-5):
--   - mg_prod 는 metagallery_prod 에만 CONNECT 가능, mg_dev 는 metagallery_dev 에만 가능
--   - 교차 CONNECT 권한을 부여하지 않는다
--   - PUBLIC 롤에서 DB CONNECT 와 public 스키마 CREATE 를 회수한다
--   - 테이블은 백엔드팀 마이그레이션이 app 스키마에 만든다(인프라팀은 스키마 소유권까지만)
-- =============================================================================

\set ON_ERROR_STOP on
\timing off

-- 비밀번호 해시는 scram-sha-256 으로만 저장한다.
ALTER SYSTEM SET password_encryption = 'scram-sha-256';
SELECT pg_reload_conf();

-- -----------------------------------------------------------------------------
-- 1. 롤 (LOGIN, 비밀번호는 provision.sh가 별도로 설정)
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mg_prod') THEN
    CREATE ROLE mg_prod WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
    RAISE NOTICE 'role mg_prod created (password not set yet)';
  ELSE
    RAISE NOTICE 'role mg_prod already exists - left as is';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mg_dev') THEN
    CREATE ROLE mg_dev WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
    RAISE NOTICE 'role mg_dev created (password not set yet)';
  ELSE
    RAISE NOTICE 'role mg_dev already exists - left as is';
  END IF;
END
$$;

-- 동시 접속 상한 (1GB RAM / max_connections=40 기준으로 환경별 배분)
ALTER ROLE mg_prod CONNECTION LIMIT 15;
ALTER ROLE mg_dev  CONNECTION LIMIT 10;

-- -----------------------------------------------------------------------------
-- 2. 데이터베이스
--    OWNER 는 postgres 로 둔다. 롤이 DB 소유자면 회수한 권한을 스스로 되돌릴 수 있다.
--    CREATE DATABASE 는 트랜잭션·DO 블록 안에서 못 돌리므로 \gexec 로 조건 실행한다.
-- -----------------------------------------------------------------------------
SELECT 'CREATE DATABASE metagallery_prod OWNER postgres ENCODING ''UTF8'' TEMPLATE template0 LC_COLLATE ''C.UTF-8'' LC_CTYPE ''C.UTF-8'''
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'metagallery_prod')
\gexec

SELECT 'CREATE DATABASE metagallery_dev OWNER postgres ENCODING ''UTF8'' TEMPLATE template0 LC_COLLATE ''C.UTF-8'' LC_CTYPE ''C.UTF-8'''
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'metagallery_dev')
\gexec

-- -----------------------------------------------------------------------------
-- 3. DB 수준 권한: PUBLIC 회수 후 해당 환경 롤에만 CONNECT 부여
--    (mg_dev 에게 metagallery_prod CONNECT 를 주지 않는다 — 교차 접근 차단의 핵심)
-- -----------------------------------------------------------------------------
REVOKE ALL ON DATABASE metagallery_prod FROM PUBLIC;
REVOKE ALL ON DATABASE metagallery_dev  FROM PUBLIC;

GRANT CONNECT, TEMPORARY ON DATABASE metagallery_prod TO mg_prod;
GRANT CONNECT, TEMPORARY ON DATABASE metagallery_dev  TO mg_dev;

-- 혹시 과거 실행에서 교차 부여가 있었다면 되돌린다(권한 회수만, 데이터 영향 없음).
REVOKE ALL ON DATABASE metagallery_prod FROM mg_dev;
REVOKE ALL ON DATABASE metagallery_dev  FROM mg_prod;

-- -----------------------------------------------------------------------------
-- 4. 운영계 DB 내부: public 스키마 잠그고 app 스키마를 롤에게 준다
-- -----------------------------------------------------------------------------
\connect metagallery_prod

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT  USAGE  ON SCHEMA public TO mg_prod;

CREATE SCHEMA IF NOT EXISTS app AUTHORIZATION mg_prod;
ALTER  SCHEMA app OWNER TO mg_prod;

-- 백엔드 마이그레이션이 별도 설정 없이 app 스키마에 테이블을 만들도록 search_path 고정
ALTER ROLE mg_prod IN DATABASE metagallery_prod SET search_path = app, public;

-- mg_dev 는 이 DB에 CONNECT 자체가 없지만, 방어적으로 스키마 권한도 비워 둔다.
REVOKE ALL ON SCHEMA app, public FROM mg_dev;

-- -----------------------------------------------------------------------------
-- 5. 개발계 DB 내부: 동일 구조
-- -----------------------------------------------------------------------------
\connect metagallery_dev

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT  USAGE  ON SCHEMA public TO mg_dev;

CREATE SCHEMA IF NOT EXISTS app AUTHORIZATION mg_dev;
ALTER  SCHEMA app OWNER TO mg_dev;

ALTER ROLE mg_dev IN DATABASE metagallery_dev SET search_path = app, public;

REVOKE ALL ON SCHEMA app, public FROM mg_prod;

-- -----------------------------------------------------------------------------
-- 6. 확인 쿼리 (설치 직후 눈으로 보는 용도)
-- -----------------------------------------------------------------------------
\connect postgres

\echo '--- 접속 바인딩 (localhost 여야 한다) ---'
SHOW listen_addresses;
\echo '--- DB별 ACL: mg_prod / mg_dev 가 자기 DB에만 보여야 한다 ---'
SELECT datname, datacl FROM pg_database WHERE datname IN ('metagallery_prod', 'metagallery_dev');
\echo '--- 롤 속성 ---'
SELECT rolname, rolsuper, rolcreatedb, rolcreaterole, rolconnlimit,
       (rolpassword IS NOT NULL) AS has_password
FROM pg_authid WHERE rolname IN ('mg_prod', 'mg_dev');

-- -----------------------------------------------------------------------------
-- 7. 보류 항목 (정보보호본부 애플리케이션보안팀 검토 대상 / 계획서 3-2)
--    기본값으로 PUBLIC 은 유지보수용 DB(postgres, template1)에 CONNECT 할 수 있다.
--    두 앱 롤이 상대 환경의 "데이터"를 읽을 수는 없지만, postgres DB에 붙어
--    pg_catalog(롤 이름·DB 목록 등 메타데이터)를 조회할 수는 있다.
--    더 조이려면 아래를 실행한다. 다만 일부 관리 도구가 postgres DB 접속을 전제로
--    동작하므로, 영향 범위를 확인한 뒤 적용해야 한다. 지금은 적용하지 않는다.
--
--      REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
--      GRANT  CONNECT ON DATABASE postgres TO postgres;
-- -----------------------------------------------------------------------------

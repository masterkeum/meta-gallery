# 메타 갤러리 인프라 - Lightsail 인스턴스 / 고정 IP / 방화벽 (계획서 1-1)

/* ---------- 인스턴스 ---------- */

resource "aws_lightsail_instance" "app" {
  name              = var.instance_name
  availability_zone = var.availability_zone
  blueprint_id      = var.blueprint_id
  bundle_id         = var.bundle_id

  # CEO가 Lightsail 콘솔에서 미리 만든 키페어 이름. null이면 리전 기본 키페어.
  key_pair_name = var.ssh_key_pair_name

  # IPv6까지 열면 방화벽 CIDR을 양쪽으로 관리해야 한다.
  # 1단계는 IPv4만 쓰고, 필요해지면 dualstack으로 올린다.
  ip_address_type = "ipv4"

  # user_data는 비워 둔다.
  # 인스턴스 내부 구성(swap 2GB, nginx, PostgreSQL, systemd)은
  # infra/server/scripts/provision.sh(팀원 3)를 SSH로 실행하는 방식이다.
  # user_data에 넣으면 실패 시 로그 추적과 재실행이 어렵다.

  # 자동 스냅샷(일 1회). 계획서 1-5에서 켜기로 확정.
  dynamic "add_on" {
    for_each = var.enable_auto_snapshot ? [1] : []

    content {
      type          = "AutoSnapshot"
      snapshot_time = var.auto_snapshot_time_utc
      status        = "Enabled"
    }
  }

  tags = {
    Name        = var.instance_name
    Environment = "shared-prod-dev"
    Role        = "web-app-db"
  }
}

/* ---------- 고정 IP ---------- */
# 인스턴스에 연결돼 있는 동안 무료다. 분리된 상태로 방치하면 과금되므로
# 인스턴스를 지울 때는 고정 IP도 같이 지운다(README 참고).

resource "aws_lightsail_static_ip" "app" {
  name = var.static_ip_name
}

resource "aws_lightsail_static_ip_attachment" "app" {
  static_ip_name = aws_lightsail_static_ip.app.name
  instance_name  = aws_lightsail_instance.app.name
}

/* ---------- 방화벽 (인바운드) ---------- */
#
# 주의: 이 리소스는 인스턴스의 포트 규칙 **전체를 대체**한다.
#       여기에 없는 포트는 모두 닫힌다(Lightsail 기본 규칙 포함).
#
# 열리는 포트
#   - TCP 80  : 전체 공개 (HTTP → HTTPS 리다이렉트 + Let's Encrypt HTTP-01 챌린지)
#   - TCP 443 : 전체 공개 (HTTPS)
#   - TCP 22  : var.ssh_allowed_cidrs(관리자 접속 IP)만
#
# 절대 열지 않는 포트
#   - TCP 5432 (PostgreSQL) : localhost 바인딩만 쓴다. 계획서 1-5 원칙.
#   - TCP 3000/3001 (백엔드) : 루프백 전용. nginx가 프록시한다.
#   - ICMP : 1단계에서는 열지 않는다. 필요하면 별도 요청으로 추가한다.

resource "aws_lightsail_instance_public_ports" "app" {
  instance_name = aws_lightsail_instance.app.name

  port_info {
    protocol  = "tcp"
    from_port = 80
    to_port   = 80
    cidrs     = var.web_allowed_cidrs
  }

  port_info {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443
    cidrs     = var.web_allowed_cidrs
  }

  port_info {
    protocol  = "tcp"
    from_port = 22
    to_port   = 22
    cidrs     = var.ssh_allowed_cidrs
  }
}

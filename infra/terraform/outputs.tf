# 메타 갤러리 인프라 - 출력값
#
# 여기에는 비밀값을 출력하지 않는다(SSH 개인키·DB 비밀번호·토큰 없음).
# 공인 IP와 버킷 이름은 공개돼도 무해한 값이지만, state 파일 자체는
# 로컬에 두고 저장소에 커밋하지 않는다(.gitignore의 *.tfstate - 팀원 1 담당).

/* ---------- Lightsail ---------- */

output "instance_name" {
  description = "Lightsail 인스턴스 이름."
  value       = aws_lightsail_instance.app.name
}

output "instance_username" {
  description = "Lightsail이 만든 기본 SSH 계정 이름(Ubuntu 블루프린트는 보통 ubuntu)."
  value       = aws_lightsail_instance.app.username
}

output "static_ip_address" {
  description = "인스턴스에 연결된 고정 IP. DuckDNS 두 서브도메인이 이 IP를 가리켜야 한다."
  value       = aws_lightsail_static_ip.app.ip_address
}

output "ssh_command" {
  description = "접속 명령 예시. 개인키 경로는 CEO 로컬 경로로 바꾼다."
  value       = "ssh -i <개인키 경로> ${aws_lightsail_instance.app.username}@${aws_lightsail_static_ip.app.ip_address}"
}

output "duckdns_dns_targets" {
  description = <<-EOT
    DuckDNS에 등록해야 하는 호스트명 → IP 대응표(계획서 1-3).
    실제 등록은 infra/duckdns/(팀원 4) 스크립트와 CEO의 DuckDNS 계정으로 한다.
  EOT
  value = {
    "metagallery.duckdns.org"     = aws_lightsail_static_ip.app.ip_address
    "metagallery-dev.duckdns.org" = aws_lightsail_static_ip.app.ip_address
  }
}

output "auto_snapshot_enabled" {
  description = "Lightsail 자동 스냅샷(일 1회) 활성화 여부."
  value       = var.enable_auto_snapshot
}

output "open_inbound_ports" {
  description = "열린 인바운드 포트 요약. 5432가 여기 보이면 안 된다."
  value = {
    "tcp/80"  = var.web_allowed_cidrs
    "tcp/443" = var.web_allowed_cidrs
    "tcp/22"  = var.ssh_allowed_cidrs
  }
}

/* ---------- S3 ---------- */

output "bucket_names" {
  description = "만들어진 S3 버킷 이름(논리 키 → 실제 이름)."
  value       = { for k, v in aws_s3_bucket.this : k => v.id }
}

output "bucket_arns" {
  description = "S3 버킷 ARN. 인스턴스용 IAM 정책을 쓸 때 참고한다."
  value       = { for k, v in aws_s3_bucket.this : k => v.arn }
}

output "backup_upload_prefix" {
  description = <<-EOT
    pg_dump 업로드 대상 경로(계획서 1-5).
    백업 스크립트(infra/server/scripts/backup-postgres.sh - 팀원 3)가 쓰는 값과 일치해야 한다.
  EOT
  value       = "s3://${aws_s3_bucket.this["backups"].id}/postgres/<env>/YYYY/MM/DD/"
}

output "bucket_name_suffix_hint" {
  description = <<-EOT
    버킷 이름이 전역에서 선점됐을 때 쓸 접미사 후보(AWS 계정 ID 뒤 4자리, 계획서 1-4 대체 규칙).
    이 값을 terraform.tfvars의 bucket_name_suffix에 넣고 다시 apply한다.
  EOT
  value       = substr(data.aws_caller_identity.current.account_id, 8, 4)
}

output "bucket_public_access" {
  description = "버킷 공개 범위 요약. 1단계는 세 버킷 모두 완전 비공개다."
  value       = "all-private (Block Public Access 4/4 ON, ACL disabled, TLS enforced)"
}

# 메타 갤러리 인프라 - S3 버킷 3개 (계획서 1-4)
#
# 보안 기조: 1단계는 **세 버킷 모두 완전 비공개**다.
#   - Block Public Access 4개 항목 전부 ON
#   - ACL 비활성(BucketOwnerEnforced)
#   - 버전 관리 ON
#   - 기본 암호화 SSE-S3(AES256)
#   - 평문 HTTP(aws:SecureTransport=false) 거부 정책
# 에셋을 외부에 공개해야 할 상황이 오면 버킷을 공개로 바꾸지 않고
# CloudFront + OAC를 앞에 둔다. → CEO 결정 대기(계획서 5장 1번).

/* ---------- 버킷 본체 ---------- */

resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket = each.value.name

  # 삭제 방지: 버킷 안에 객체가 있으면 destroy가 실패하게 둔다(기본값 false).
  # 백업·운영 데이터를 실수로 날리지 않기 위한 안전장치다.
  force_destroy = false

  tags = {
    Name        = each.value.name
    Environment = each.value.env
    Purpose     = each.value.purpose
    Public      = "false"
  }
}

/* ---------- 퍼블릭 접근 차단 (4항목 전부 ON) ---------- */

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

/* ---------- ACL 비활성화 (소유자 강제) ---------- */

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

/* ---------- 버전 관리 ---------- */

resource "aws_s3_bucket_versioning" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

/* ---------- 기본 암호화 (SSE-S3 / AES256) ---------- */
# KMS(SSE-KMS)는 키 요금과 요청당 과금이 붙어 최소 비용 기조(월 $7급 인스턴스 1대)에 맞지 않는다.
# 규제 요건이 생기면 SSE-KMS로 올리는 것을 정보보호팀과 검토한다.

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = false
  }
}

/* ---------- TLS 강제 정책 ---------- */
# 계정 ID를 하드코딩하지 않기 위해 리소스 ARN은 버킷 이름으로만 구성한다.

data "aws_iam_policy_document" "deny_insecure_transport" {
  for_each = local.buckets

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.this[each.key].arn,
      "${aws_s3_bucket.this[each.key].arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id
  policy = data.aws_iam_policy_document.deny_insecure_transport[each.key].json

  # 퍼블릭 차단이 먼저 켜진 뒤 정책을 붙인다(정책 적용 중 공개 노출 창 제거).
  depends_on = [aws_s3_bucket_public_access_block.this]
}

/* ---------- 수명주기: 에셋 버킷 ---------- */
# 이전 버전 30일 후 삭제. 현재 버전은 삭제하지 않는다.

resource "aws_s3_bucket_lifecycle_configuration" "assets" {
  for_each = toset(local.asset_bucket_keys)

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.asset_noncurrent_version_expiration_days
    }
  }

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

/* ---------- 수명주기: 백업 버킷 ---------- */
# 30일 후 Glacier Instant Retrieval 전환, 180일 후 삭제.

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  for_each = toset(local.backup_bucket_keys)

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    id     = "archive-then-expire"
    status = "Enabled"

    filter {}

    transition {
      days          = var.backup_glacier_ir_transition_days
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = var.backup_expiration_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

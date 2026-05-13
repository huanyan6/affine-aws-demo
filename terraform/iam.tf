resource "aws_iam_policy" "affine_s3" {
  name = "${var.project}-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AFFiNES3Access"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          "arn:aws:s3:::${local.s3_bucket}",
          "arn:aws:s3:::${local.s3_bucket}/*",
        ]
      },
    ]
  })
}

resource "aws_iam_group" "this" {
  name = "${var.project}-group"
}

resource "aws_iam_group_policy_attachment" "this" {
  group      = aws_iam_group.this.name
  policy_arn = aws_iam_policy.affine_s3.arn
}

resource "aws_iam_user" "this" {
  name = "${var.project}-deployer"

  tags = {
    Project = var.project
  }
}

resource "aws_iam_user_group_membership" "this" {
  user   = aws_iam_user.this.name
  groups = [aws_iam_group.this.name]
}

resource "aws_iam_access_key" "this" {
  user = aws_iam_user.this.name
}

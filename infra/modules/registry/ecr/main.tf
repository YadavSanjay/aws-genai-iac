# ECR repositories: KMS-encrypted, immutable tags, scanned on push, lifecycled.
#
# The lifecycle policy is not optional here. An image repository is the classic
# silent cost leak: every build adds layers, nothing ever removes them, and the
# growth is invisible until it appears on a bill.

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repositories)

  name                 = each.value
  image_tag_mutability = var.image_tag_mutability
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  # KMS rather than the AES256 default, so image layers are covered by the same
  # key policy and rotation as everything else. ECR is in the CMK's
  # kms:ViaService list, so no key-policy change is needed.
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = merge(var.tags, {
    Name = each.value
  })
}

# Two rules, evaluated in priority order.
#
# Rule 1 clears untagged images quickly — they are the residue of overwritten or
# failed pushes and nothing references them.
#
# Rule 2 bounds tagged history. It uses tagPrefixList = [""] with
# tagStatus = "any" rather than "tagged", because "tagged" requires an explicit
# prefix list and would silently skip images whose tags do not match.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${var.untagged_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expiry_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Retain only the most recent ${var.keep_tagged_images} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.keep_tagged_images
        }
        action = { type = "expire" }
      },
    ]
  })
}

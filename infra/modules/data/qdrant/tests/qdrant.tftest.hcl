# Plan-time tests for the Qdrant host. Mocked provider, no AWS credentials.
#
#   terraform -chdir=infra/modules/data/qdrant test
#
# The security posture that must hold regardless of inputs: private (no public
# IP), IMDSv2 required, both volumes CMK-encrypted, a separate persistent data
# volume, the instance role carries the permissions boundary, and the store is
# discoverable by a stable name. Post-apply, tests/integration verifies the live
# host and that Qdrant rejects a request with no API key.

mock_provider "aws" {
  # aws_iam_policy_document under a mocked provider yields no .json; stub a valid
  # empty policy so the roles that consume it can be created in the test.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  name_prefix              = "genai-dev"
  subnet_id                = "subnet-00000000000000000"
  security_group_ids       = ["sg-00000000000000000"]
  kms_key_arn              = "arn:aws:kms:us-east-1:000000000000:key/00000000-0000-0000-0000-000000000000"
  permissions_boundary_arn = "arn:aws:iam::000000000000:policy/genai-app-boundary"
  image                    = "000000000000.dkr.ecr.us-east-1.amazonaws.com/genai-dev/qdrant:v1.18.2"
  ecr_repository_arns      = ["arn:aws:ecr:us-east-1:000000000000:repository/genai-dev/qdrant"]
  secret_arn               = "arn:aws:secretsmanager:us-east-1:000000000000:secret:genai-dev/qdrant/app-abc123"

  service_discovery_namespace_id   = "ns-00000000000000000"
  service_discovery_namespace_name = "genai-dev.internal"
}

run "host_is_private_encrypted_and_discoverable" {
  command = apply

  # Private: no public address.
  assert {
    condition     = aws_instance.qdrant.associate_public_ip_address == false
    error_message = "the Qdrant host must not have a public IP"
  }

  # IMDSv2 required, hop limit 2 (a container must reach IMDS for boot creds).
  assert {
    condition     = aws_instance.qdrant.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required (http_tokens=required)"
  }
  assert {
    condition     = aws_instance.qdrant.metadata_options[0].http_put_response_hop_limit == 2
    error_message = "IMDS hop limit must be 2 so the containerized Qdrant can obtain instance-role creds"
  }

  # Root volume CMK-encrypted.
  assert {
    condition     = aws_instance.qdrant.root_block_device[0].encrypted == true && aws_instance.qdrant.root_block_device[0].kms_key_id == var.kms_key_arn
    error_message = "root volume must be encrypted with the CMK"
  }

  # A SEPARATE, CMK-encrypted gp3 data volume — so data survives instance replacement.
  assert {
    condition     = aws_ebs_volume.data.encrypted == true && aws_ebs_volume.data.kms_key_id == var.kms_key_arn && aws_ebs_volume.data.type == "gp3"
    error_message = "the data volume must be a separate CMK-encrypted gp3 volume"
  }

  # Instance role carries the permissions boundary (blast-radius containment).
  assert {
    condition     = aws_iam_role.qdrant.permissions_boundary == var.permissions_boundary_arn
    error_message = "the instance role must carry the permissions boundary"
  }

  # Stable discovery name.
  assert {
    condition     = aws_service_discovery_service.qdrant.name == "qdrant"
    error_message = "the host must register as qdrant.<namespace> for in-VPC discovery"
  }
}

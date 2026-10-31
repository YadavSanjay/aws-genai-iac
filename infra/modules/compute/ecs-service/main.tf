# ECS Fargate service: a container application behind an IP target group.
#
# The workhorse for services that run on Fargate rather than a compose EC2 host
# (RagInference: CPU/ARM64 model server). Tasks run in private subnets with no
# public IP, reach AWS via VPC endpoints/NAT, and are administered via ECS Exec
# (there is no SSH into Fargate).
#
# This module OWNS its target group (target_type = ip) and the service registers
# task IPs to it. The shared ALB attaches to that target group with a listener
# rule (edge/alb), so the target group's lifecycle is tied to the SERVICE, not to
# the ingress toggle — flipping ingress to "ssm" removes the ALB and its rule but
# leaves the service and its (unfronted) target group intact.

locals {
  full_name = "${var.name_prefix}-${var.app_name}"

  # A KMS-encrypted, unencrypted, or public path does not exist here: encryption
  # is required and public IPs are off by default.
  object_arns = [for arn in var.task_read_bucket_arns : "${arn}/*"]
}

data "aws_region" "current" {}

# --- Log group ---------------------------------------------------------------

resource "aws_cloudwatch_log_group" "this" {
  # CKV_AWS_338 wants >= 1 year retention. That is a prod/compliance answer; dev
  # keeps logs short for cost. What the baseline actually requires is that
  # retention is set EXPLICITLY rather than left at "never expire" — which it is.
  # Raise log_retention_days in prod.
  #checkov:skip=CKV_AWS_338:Dev keeps short retention for cost; retention is set explicitly (not never-expire), which is the requirement. Prod raises to >=1yr.
  name              = "/ecs/${local.full_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, {
    Name = "/ecs/${local.full_name}"
    App  = var.app_name
  })
}

# ECS Exec is interactive access to a running container (the Fargate equivalent
# of an SSH session), so its sessions are audited: logged to a CMK-encrypted
# group, separate from the application's own logs.
resource "aws_cloudwatch_log_group" "exec" {
  #checkov:skip=CKV_AWS_338:Dev keeps short retention for cost; retention is set explicitly. Prod raises to >=1yr.
  name              = "/ecs/${local.full_name}/exec"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, {
    Name = "/ecs/${local.full_name}/exec"
    App  = var.app_name
  })
}

# --- Execution role (the ECS agent: pull image, write logs, read secrets) ----

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name                 = "${local.full_name}-exec"
  description          = "ECS execution role for ${var.app_name}: scoped ECR pull, log write, secret read."
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary_arn

  tags = var.tags
}

data "aws_iam_policy_document" "execution" {
  # GetAuthorizationToken mints a registry-wide login token and takes no
  # resource; the actual pull is scoped by the next statement.
  dynamic "statement" {
    for_each = length(var.ecr_repository_arns) > 0 ? [1] : []

    content {
      sid       = "EcrLogin"
      effect    = "Allow"
      actions   = ["ecr:GetAuthorizationToken"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = length(var.ecr_repository_arns) > 0 ? [1] : []

    content {
      sid       = "EcrPullOwnImagesOnly"
      effect    = "Allow"
      actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
      resources = var.ecr_repository_arns
    }
  }

  statement {
    sid    = "WriteOwnLogsOnly"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  dynamic "statement" {
    for_each = length(var.secrets) > 0 ? [1] : []

    content {
      sid       = "ReadInjectedSecretsOnly"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = values(var.secrets)
    }
  }

  # Decrypting KMS-encrypted ECR image layers (and injected secrets) calls KMS on
  # the agent's behalf. Scoped to the one CMK.
  statement {
    sid       = "DecryptImageLayersAndSecrets"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "execution"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

# --- Task role (the container's own identity: read weights, ECS Exec) ---------

resource "aws_iam_role" "task" {
  name                 = "${local.full_name}-task"
  description          = "Task role for ${var.app_name}: scoped S3 read and ECS Exec channels only."
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary_arn

  tags = var.tags
}

data "aws_iam_policy_document" "task" {
  # Read ITS OWN buckets only (e.g. the weights bucket) — not every bucket.
  dynamic "statement" {
    for_each = length(var.task_read_bucket_arns) > 0 ? [1] : []

    content {
      sid       = "ListOwnBuckets"
      effect    = "Allow"
      actions   = ["s3:ListBucket"]
      resources = var.task_read_bucket_arns
    }
  }

  dynamic "statement" {
    for_each = length(var.task_read_bucket_arns) > 0 ? [1] : []

    content {
      sid       = "ReadOwnObjects"
      effect    = "Allow"
      actions   = ["s3:GetObject"]
      resources = local.object_arns
    }
  }

  # Decrypt the KMS-encrypted objects read above. Read-only: Decrypt, not
  # GenerateDataKey.
  dynamic "statement" {
    for_each = length(var.task_read_bucket_arns) > 0 ? [1] : []

    content {
      sid       = "DecryptOwnObjects"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [var.kms_key_arn]
    }
  }

  # ECS Exec (the Fargate equivalent of Session Manager). The channel actions
  # take no resource — they are gated by the service's enableExecuteCommand and
  # the task role trust, not by ARN.
  dynamic "statement" {
    for_each = var.enable_execute_command ? [1] : []

    content {
      sid    = "EcsExecChannels"
      effect = "Allow"
      actions = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      resources = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "task" {
  # A role policy with zero statements is invalid, so only attach when the task
  # role actually needs something (buckets or exec).
  count = (length(var.task_read_bucket_arns) > 0 || var.enable_execute_command) ? 1 : 0

  name   = "task"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

# --- Cluster -----------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  # CKV_AWS_65 (Container Insights): $0-ish at rest but it charges per ingested
  # metric/log and adds up on a chatty cluster. Not justified for a single-task
  # dev service whose signals come from the target group health check and the
  # app's own /metrics. Enable in prod, or when there is a dashboard consuming it.
  #checkov:skip=CKV_AWS_65:Container Insights bills per metric; not justified for one dev task. The TG health check and app metrics are the signal. Enable in prod.
  name = local.full_name

  configuration {
    execute_command_configuration {
      # ECS Exec traffic is encrypted with the same CMK, and sessions are logged
      # to a CMK-encrypted group for audit rather than left to the default.
      kms_key_id = var.kms_key_arn
      logging    = "OVERRIDE"

      log_configuration {
        cloud_watch_encryption_enabled = true
        cloud_watch_log_group_name     = aws_cloudwatch_log_group.exec.name
      }
    }
  }

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = merge(var.tags, {
    Name = local.full_name
    App  = var.app_name
  })
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

# --- Task definition ---------------------------------------------------------

resource "aws_ecs_task_definition" "this" {
  # CKV_AWS_336 (read-only root filesystem): deliberately false. The service
  # syncs ~4 GB of model weights to HF_HOME on the root filesystem at startup
  # (MODEL_SOURCE=s3); a read-only root would break that documented path. The
  # task carries no long-lived secrets on disk and is replaced, not patched.
  #checkov:skip=CKV_AWS_336:App writes model weights to HF_HOME at runtime; a read-only root FS breaks the documented S3 model-sync.
  family                   = local.full_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    cpu_architecture        = var.cpu_architecture
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      name         = var.app_name
      image        = var.image
      essential    = true
      portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]

      environment = [for k, v in var.environment : { name = k, value = v }]
      secrets     = [for k, v in var.secrets : { name = k, valueFrom = v }]

      # A read-only root FS is not used (see the checkov note above); state this
      # explicitly rather than leaving it to a provider default.
      readonlyRootFilesystem = false

      # ECS-managed init reaps zombie processes; the image also runs tini as
      # PID 1, so this is belt-and-suspenders and required for a clean ECS Exec.
      linuxParameters = { initProcessEnabled = true }

      healthCheck = var.container_health_check == null ? null : {
        command     = var.container_health_check.command
        interval    = var.container_health_check.interval
        timeout     = var.container_health_check.timeout
        retries     = var.container_health_check.retries
        startPeriod = var.container_health_check.start_period
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = var.app_name
        }
      }

      stopTimeout = 30
    }
  ])

  tags = merge(var.tags, {
    Name = local.full_name
    App  = var.app_name
  })
}

# --- Service discovery (Cloud Map) -------------------------------------------
#
# The per-service record in the shared namespace, so the service resolves at
# <app_name>.<namespace>. ECS registers a task's IP here when it reaches RUNNING.
#
# No health_check_custom_config: its only field (failure_threshold) is deprecated
# and an empty block never persists, so terraform re-adds it every apply and
# force-replaces the service (churning the DNS record). The task's readiness is
# already gated where it matters — the container_health_check makes the ECS
# DEPLOYMENT wait for /readyz before it completes. During a scale-from-zero warm
# a caller may briefly resolve a task still returning 503; that is the documented
# cold-start SLO, and clients are expected to retry.

resource "aws_service_discovery_service" "this" {
  count = var.service_discovery_namespace_id != "" ? 1 : 0

  name = var.app_name

  dns_config {
    namespace_id   = var.service_discovery_namespace_id
    routing_policy = "MULTIVALUE"

    dns_records {
      type = "A"
      # Short TTL: task IPs change on every replacement/scale event, so a long
      # TTL would leave clients resolving a dead IP after a redeploy.
      ttl = 15
    }
  }

  tags = merge(var.tags, {
    Name = "${local.full_name}.discovery"
    App  = var.app_name
  })
}

# --- Service -----------------------------------------------------------------

resource "aws_ecs_service" "this" {
  name            = local.full_name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count

  # On-demand FARGATE, or FARGATE_SPOT when the caller accepts interruption for
  # the ~70% saving.
  capacity_provider_strategy {
    capacity_provider = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }

  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = var.deployment_maximum_percent

  # Roll back automatically if a new task definition never reaches a healthy
  # state, rather than sitting in a failed deploy.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  enable_execute_command = var.enable_execute_command
  wait_for_steady_state  = var.wait_for_steady_state

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = var.assign_public_ip
  }

  # Attach to a load balancer only when an (already LB-associated) target group is
  # given. Backend services use service discovery instead and create neither.
  dynamic "load_balancer" {
    for_each = var.target_group_arn != "" ? [1] : []

    content {
      target_group_arn = var.target_group_arn
      container_name   = var.app_name
      container_port   = var.container_port
    }
  }

  dynamic "service_registries" {
    for_each = var.service_discovery_namespace_id != "" ? [1] : []

    content {
      registry_arn = aws_service_discovery_service.this[0].arn
    }
  }

  # ECS accepts a grace period ONLY with a load balancer. For a discovery-only
  # service the container health check's start_period covers the cold start.
  health_check_grace_period_seconds = var.target_group_arn != "" ? var.health_check_grace_period_seconds : null

  # Capacity is owned by Application Auto Scaling once enabled, not by a Terraform
  # value that would reset desired_count to its literal on every apply and fight
  # the scheduled scale-to-zero. The starting count is set on create; changes
  # thereafter come from autoscaling or the CLI.
  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = merge(var.tags, {
    Name = local.full_name
    App  = var.app_name
  })

  depends_on = [aws_ecs_cluster_capacity_providers.this]
}

# --- Scheduled scale-to-zero (opt-in) ----------------------------------------

resource "aws_appautoscaling_target" "this" {
  count = var.enable_autoscaling ? 1 : 0

  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.autoscaling_min_capacity
  max_capacity       = var.autoscaling_max_capacity
}

resource "aws_appautoscaling_scheduled_action" "up" {
  count = var.enable_autoscaling && var.scale_up_cron != "" ? 1 : 0

  name               = "${local.full_name}-up"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  schedule           = var.scale_up_cron
  timezone           = var.schedule_timezone

  scalable_target_action {
    min_capacity = var.autoscaling_max_capacity
    max_capacity = var.autoscaling_max_capacity
  }
}

resource "aws_appautoscaling_scheduled_action" "down" {
  count = var.enable_autoscaling && var.scale_down_cron != "" ? 1 : 0

  name               = "${local.full_name}-down"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  schedule           = var.scale_down_cron
  timezone           = var.schedule_timezone

  scalable_target_action {
    min_capacity = var.autoscaling_min_capacity
    max_capacity = var.autoscaling_min_capacity
  }
}

# --- Alarms (opt-in) ---------------------------------------------------------
#
# AWS/ECS service metrics (CPU/memory utilization) are published without
# Container Insights, so these cost nothing extra. treat_missing_data =
# notBreaching: a scaled-to-zero service emits no datapoints, and "no task" is
# not an alarm condition.

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${local.full_name}-cpu-high"
  alarm_description   = "${var.app_name} task CPU utilization sustained above ${var.alarm_cpu_threshold}%."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.alarm_cpu_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.this.name
    ServiceName = aws_ecs_service.this.name
  }

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions

  tags = merge(var.tags, { Name = "${local.full_name}-cpu-high", App = var.app_name })
}

resource "aws_cloudwatch_metric_alarm" "memory_high" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${local.full_name}-memory-high"
  alarm_description   = "${var.app_name} task memory utilization above ${var.alarm_memory_threshold}% — OOM risk / right-size up."
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.alarm_memory_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.this.name
    ServiceName = aws_ecs_service.this.name
  }

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions

  tags = merge(var.tags, { Name = "${local.full_name}-memory-high", App = var.app_name })
}

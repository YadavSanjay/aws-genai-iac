# Plan-time tests for compute/ecs-service. Runs with NO AWS credentials via a
# mocked provider, so it is part of the fast gate rather than post-apply.
#
#   terraform -chdir=infra/modules/compute/ecs-service test
#
# Asserts the module's SHAPE and the decisions that must not regress: ARM64
# Fargate, two distinct boundaried roles, retention + CMK on the log group,
# audited ECS Exec, opt-in scale-to-zero, and the two reachability modes —
# Cloud Map service discovery (backend default) vs an external target group.

# The aws_iam_policy_document data source renders JSON locally in the real
# provider; a bare mock returns a non-JSON stub that fails assume_role_policy
# validation. Give it valid JSON — these tests assert SHAPE, not policy CONTENT.
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  name_prefix              = "genai-dev"
  app_name                 = "raginference"
  image                    = "111122223333.dkr.ecr.us-east-1.amazonaws.com/genai-dev/raginference:abc1234"
  cpu                      = 4096
  memory                   = 16384
  container_port           = 8799
  subnet_ids               = ["subnet-00000000000000001", "subnet-00000000000000002"]
  security_group_ids       = ["sg-00000000000000000"]
  kms_key_arn              = "arn:aws:kms:us-east-1:111122223333:key/00000000-0000-0000-0000-000000000000"
  permissions_boundary_arn = "arn:aws:iam::111122223333:policy/genai-app-boundary"
  ecr_repository_arns      = ["arn:aws:ecr:us-east-1:111122223333:repository/genai-dev/raginference"]
  task_read_bucket_arns    = ["arn:aws:s3:::genai-dev-raginference-weights-us-east-1"]
  environment = {
    DEPLOY_MODE  = "aws"
    MODEL_SOURCE = "s3"
    MODEL_S3_URI = "s3://genai-dev-raginference-weights-us-east-1"
  }
}

run "backend_service_discovery_default" {
  command = plan

  variables {
    service_discovery_namespace_id   = "ns-00000000000000000"
    service_discovery_namespace_name = "genai-dev.internal"
    enable_alarms                    = true
    container_health_check = {
      command      = ["CMD-SHELL", "curl -f http://127.0.0.1:8799/readyz || exit 1"]
      start_period = 600
    }
  }

  # --- Fargate / ARM64 task shape ---
  assert {
    condition     = aws_ecs_task_definition.this.cpu == "4096" && aws_ecs_task_definition.this.memory == "16384"
    error_message = "task cpu/memory not passed through"
  }
  assert {
    condition     = one(aws_ecs_task_definition.this.runtime_platform).cpu_architecture == "ARM64"
    error_message = "task must be ARM64 (Graviton)"
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].portMappings[0].containerPort == 8799
    error_message = "container port must be 8799"
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].readonlyRootFilesystem == false
    error_message = "read-only root must be false so the weight sync can write HF_HOME"
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].healthCheck.startPeriod == 600
    error_message = "container health check must carry the generous start period"
  }

  # --- Service discovery, NOT a load balancer ---
  assert {
    condition     = length(aws_service_discovery_service.this) == 1
    error_message = "a Cloud Map service must be created when a namespace id is given"
  }
  assert {
    condition     = length(aws_ecs_service.this.service_registries) == 1
    error_message = "the service must register into Cloud Map"
  }
  assert {
    condition     = length(aws_ecs_service.this.load_balancer) == 0
    error_message = "a discovery-only service must NOT attach a load balancer"
  }
  assert {
    condition     = one(aws_service_discovery_service.this).name == "raginference"
    error_message = "the discovery record must be named for the app"
  }

  # --- two distinct roles, both boundaried ---
  assert {
    condition     = aws_iam_role.execution.name != aws_iam_role.task.name
    error_message = "execution and task roles must be distinct"
  }
  assert {
    condition     = aws_iam_role.execution.permissions_boundary == var.permissions_boundary_arn && aws_iam_role.task.permissions_boundary == var.permissions_boundary_arn
    error_message = "both roles must carry the permissions boundary"
  }

  # --- log group: retention + CMK; ECS Exec audited ---
  assert {
    condition     = aws_cloudwatch_log_group.this.retention_in_days == 30 && aws_cloudwatch_log_group.this.kms_key_id == var.kms_key_arn
    error_message = "log group must have explicit retention and be CMK-encrypted"
  }
  assert {
    condition     = one(one(aws_ecs_cluster.this.configuration).execute_command_configuration).logging == "OVERRIDE"
    error_message = "ECS Exec sessions must be audit-logged (OVERRIDE)"
  }

  # --- on-demand FARGATE by default; scale-to-zero is opt-in ---
  assert {
    condition     = one(aws_ecs_service.this.capacity_provider_strategy).capacity_provider == "FARGATE"
    error_message = "default must be on-demand FARGATE, not SPOT"
  }
  assert {
    condition     = length(aws_appautoscaling_target.this) == 0
    error_message = "autoscaling must not exist unless enable_autoscaling = true"
  }

  # --- alarms exist and tolerate a scaled-to-zero (no-datapoint) service ---
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.cpu_high) == 1 && length(aws_cloudwatch_metric_alarm.memory_high) == 1
    error_message = "enable_alarms must create the CPU and memory alarms"
  }
  assert {
    condition     = one(aws_cloudwatch_metric_alarm.memory_high).treat_missing_data == "notBreaching"
    error_message = "a scaled-to-zero service emits no datapoints; missing data must not breach"
  }
}

run "external_target_group_mode" {
  command = plan

  variables {
    target_group_arn = "arn:aws:elasticloadbalancing:us-east-1:111122223333:targetgroup/genai-dev-x/abc123"
  }

  assert {
    condition     = length(aws_ecs_service.this.load_balancer) == 1
    error_message = "an external target group must attach a load balancer block"
  }
  assert {
    condition     = one(aws_ecs_service.this.load_balancer).target_group_arn == var.target_group_arn
    error_message = "the load balancer must reference the given target group"
  }
  assert {
    condition     = aws_ecs_service.this.health_check_grace_period_seconds == 300
    error_message = "the grace period applies only in load-balancer mode"
  }
  assert {
    condition     = length(aws_service_discovery_service.this) == 0
    error_message = "no Cloud Map service in external-target mode"
  }
}

run "autoscaling_when_enabled" {
  command = plan

  variables {
    service_discovery_namespace_id = "ns-00000000000000000"
    enable_autoscaling             = true
    scale_up_cron                  = "cron(0 11 ? * MON-FRI *)"
    scale_down_cron                = "cron(0 21 ? * MON-FRI *)"
    schedule_timezone              = "America/New_York"
  }

  assert {
    condition     = one(aws_appautoscaling_target.this).min_capacity == 0
    error_message = "scalable target must allow scale-to-zero (min 0)"
  }
  assert {
    condition     = length(aws_appautoscaling_scheduled_action.up) == 1 && length(aws_appautoscaling_scheduled_action.down) == 1
    error_message = "both scheduled actions must exist when crons are set"
  }
  assert {
    condition     = tostring(one(aws_appautoscaling_scheduled_action.down).scalable_target_action[0].max_capacity) == "0"
    error_message = "the down action must scale to zero"
  }
}

run "spot_when_requested" {
  command = plan

  variables {
    use_fargate_spot = true
  }

  assert {
    condition     = one(aws_ecs_service.this.capacity_provider_strategy).capacity_provider == "FARGATE_SPOT"
    error_message = "use_fargate_spot must select FARGATE_SPOT"
  }
}

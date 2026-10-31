# Environment-level locals shared by all components in dev.
locals {
  name        = "dev"
  name_prefix = "genai-dev"
  vpc_cidr    = "10.10.0.0/16"

  # --- Public ingress mode: "alb" or "ssm" ----------------------------------
  #
  # THE SWITCH. Governs every application in this environment — MacroRAG, ARag,
  # Faultline and RagInference become reachable, or unreachable-except-by-
  # SSM, together. See docs/design/aws-service-consolidation.md §2b.
  #
  #   "alb"  Shared Application Load Balancer. Public URL, path-based routing.
  #          $16.43/month, and it CANNOT be stopped — an ALB bills 24 hours a
  #          day even while every application behind it is scheduled off.
  #
  #   "ssm"  No load balancer at all. Reach an application through a Session
  #          Manager tunnel, which needs no infrastructure and exposes nothing:
  #
  #            aws ssm start-session --target <instance-id> \
  #              --document-name AWS-StartPortForwardingSession \
  #              --parameters '{"portNumber":["8000"],"localPortNumber":["8000"]}'
  #
  #          Then browse http://localhost:8000. $0/month.
  #
  # Use "alb" only while the subsystems genuinely need to interoperate, or an
  # external user needs access. Flip back to "ssm" afterwards — changing this
  # line and applying destroys the load balancer and stops the charge.
  #
  # Deliberately a version-controlled value rather than a console action, so an
  # environment's ingress state is always visible in git and auditable.
  ingress_mode = "ssm"

  # --- Park mode: true = the whole environment stays OFF ---------------------
  #
  # THE OTHER SWITCH. `ingress_mode` governs how the estate is reached; this
  # governs whether it runs at all. Set true to hold every compute tier down
  # indefinitely — no daily window, nothing starts on its own — while keeping
  # every resource, volume, image, secret and DNS name provisioned exactly as it
  # is. Waking up is `parked = false` + apply, NOT a re-provision.
  #
  # This exists because the estate is a demo environment funded by a fixed credit
  # balance. Idle at the 10-21 daily window it burns roughly $4/day, most of it
  # RagInference's Fargate task; parked it is about $0.68/day, nearly all of that
  # the 208 GB of EBS that bills whether or not an instance is attached to it.
  # That is the difference between the credits lasting three weeks and lasting
  # four months.
  #
  # What true does, per tier:
  #
  #   EC2 (nat, qdrant, macrorag, arag, qlp)  schedules DISABLED. A stopped EC2
  #                                           instance never restarts itself, so
  #                                           disabling both crons is sufficient.
  #   ECS (raginference)                      no scale-UP action, and the scalable
  #                                           target is bounded to 0. The daily
  #                                           scale-down stays as a backstop.
  #   RDS (arag)                              stop cron KEPT, start cron dropped.
  #                                           NOT `schedule_enabled = false` —
  #                                           RDS force-starts a stopped instance
  #                                           after seven days, so the recurring
  #                                           stop is what actually holds it down.
  #
  # Parking does NOT stop anything that is currently running; it only stops
  # things coming back. Stop the running tiers once, by hand or by letting the
  # evening crons fire one last time, and they stay down.
  #
  # Costs that survive parking and can only be removed by destroying things:
  # EBS volumes (~$16.3/mo), Secrets Manager (~$2), KMS CMKs (~$1), ECR images
  # (~$0.7), the private hosted zone ($0.50), S3 and Cloud Map (~$0.6).
  parked = true
}

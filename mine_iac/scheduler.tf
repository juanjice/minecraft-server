data "aws_caller_identity" "current" {}

locals {
  start_parts = split(":", var.start_time)
  stop_parts  = split(":", var.stop_time)

  start_hour   = tonumber(local.start_parts[0])
  start_minute = tonumber(local.start_parts[1])
  stop_hour    = tonumber(local.stop_parts[0])
  stop_minute  = tonumber(local.stop_parts[1])

  start_cron = var.schedule_days == "*" ? "cron(${local.start_minute} ${local.start_hour} * * ? *)" : "cron(${local.start_minute} ${local.start_hour} ? * ${var.schedule_days} *)"
  stop_cron  = var.schedule_days == "*" ? "cron(${local.stop_minute} ${local.stop_hour} * * ? *)" : "cron(${local.stop_minute} ${local.stop_hour} ? * ${var.schedule_days} *)"

  start_state = var.enable_scheduled_start ? "ENABLED" : "DISABLED"
  stop_state  = var.enable_scheduled_stop ? "ENABLED" : "DISABLED"
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

data "aws_iam_policy_document" "scheduler_power" {
  statement {
    actions   = ["ec2:StartInstances", "ec2:StopInstances"]
    resources = [aws_instance.minecraft_beta.arn]
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.project_name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "scheduler_power" {
  name   = "${var.project_name}-power"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler_power.json
}

resource "aws_scheduler_schedule" "start" {
  name        = "${var.project_name}-start"
  description = "Enciende el servidor de Minecraft a las ${var.start_time} (${var.timezone})"
  state       = local.start_state

  schedule_expression          = local.start_cron
  schedule_expression_timezone = var.timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      InstanceIds = [aws_instance.minecraft_beta.id]
    })

    retry_policy {
      maximum_retry_attempts       = 5
      maximum_event_age_in_seconds = 3600
    }
  }
}

resource "aws_scheduler_schedule" "stop" {
  name        = "${var.project_name}-stop"
  description = "Apaga el servidor de Minecraft a las ${var.stop_time} (${var.timezone})"
  state       = local.stop_state

  schedule_expression          = local.stop_cron
  schedule_expression_timezone = var.timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      InstanceIds = [aws_instance.minecraft_beta.id]
    })

    retry_policy {
      maximum_retry_attempts       = 5
      maximum_event_age_in_seconds = 3600
    }
  }
}

resource "random_password" "start_token" {
  length  = 40
  special = false
}

data "archive_file" "start_link" {
  type        = "zip"
  source_file = "${path.module}/lambda/start_server.py"
  output_path = "${path.module}/.build/start_server.zip"
}

data "aws_iam_policy_document" "start_link_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "start_link" {
  statement {
    sid       = "StartMinecraftInstance"
    actions   = ["ec2:StartInstances"]
    resources = [aws_instance.minecraft_beta.arn]
  }

  statement {
    sid       = "DescribeInstances"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.start_link.arn}:*"]
  }
}

resource "aws_iam_role" "start_link" {
  name               = "${var.project_name}-start-link"
  assume_role_policy = data.aws_iam_policy_document.start_link_assume.json
}

resource "aws_iam_role_policy" "start_link" {
  name   = "${var.project_name}-start-link"
  role   = aws_iam_role.start_link.id
  policy = data.aws_iam_policy_document.start_link.json
}

resource "aws_cloudwatch_log_group" "start_link" {
  name              = "/aws/lambda/${var.project_name}-start-link"
  retention_in_days = 14
}

resource "aws_lambda_function" "start_link" {
  function_name = "${var.project_name}-start-link"
  description   = "Pagina para encender el servidor de Minecraft bajo demanda"
  role          = aws_iam_role.start_link.arn

  runtime       = "python3.13"
  architectures = ["arm64"]
  handler       = "start_server.handler"
  memory_size   = 128
  timeout       = 10

  filename         = data.archive_file.start_link.output_path
  source_code_hash = data.archive_file.start_link.output_base64sha256

  environment {
    variables = {
      INSTANCE_ID       = aws_instance.minecraft_beta.id
      START_TOKEN       = random_password.start_token.result
      SERVER_PORT       = tostring(var.server_port)
      IDLE_STOP_MINUTES = tostring(var.idle_stop_minutes)
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.start_link.name
  }

  depends_on = [aws_iam_role_policy.start_link]
}

resource "aws_lambda_function_url" "start_link" {
  function_name      = aws_lambda_function.start_link.function_name
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "start_link_url" {
  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.start_link.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "start_link_invoke" {
  statement_id             = "AllowInvokeViaFunctionUrl"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.start_link.function_name
  principal                = "*"
  invoked_via_function_url = true
}

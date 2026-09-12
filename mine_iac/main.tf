data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = [var.ami_name_filter]
  }
}

resource "aws_key_pair" "minecraft" {
  key_name   = "${var.project_name}-key"
  public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))

  tags = { Name = "${var.project_name}-key" }
}

locals {
  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    mc_user           = var.minecraft_user
    mc_dir            = var.minecraft_dir
    minecraft_version = var.minecraft_version
    java_package      = var.java_package
    java_xms          = var.java_xms
    java_xmx          = var.java_xmx

    server_port = var.server_port
    rcon_port   = var.rcon_port

    motd                     = var.motd
    max_players              = var.max_players
    gamemode                 = var.gamemode
    difficulty               = var.difficulty
    level_seed               = var.level_seed
    view_distance            = var.view_distance
    simulation_distance      = var.simulation_distance
    spawn_protection         = var.spawn_protection
    pause_when_empty_seconds = var.pause_when_empty_seconds
    enable_command_block     = tostring(var.enable_command_block)

    whitelist_enabled      = tostring(var.whitelist_enabled)
    online_mode            = tostring(var.online_mode)
    enforce_secure_profile = tostring(var.online_mode)
    whitelist_players      = join(" ", var.whitelist_players)
    op_players             = join(" ", var.op_players)

    swap_size_mb          = var.swap_size_mb
    timezone              = var.timezone
    backup_dir            = var.backup_dir
    backup_retention_days = var.backup_retention_days
    backup_schedule       = var.backup_schedule
    idle_stop_minutes     = var.idle_stop_minutes
  })
}

resource "aws_instance" "minecraft_beta" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type

  instance_initiated_shutdown_behavior = "stop"

  subnet_id              = aws_subnet.minecraft.id
  vpc_security_group_ids = [aws_security_group.minecraft.id]
  key_name               = aws_key_pair.minecraft.key_name

  user_data                   = local.user_data
  user_data_replace_on_change = false

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name = "${var.project_name}-beta"
  }

  depends_on = [aws_route_table_association.minecraft]

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

resource "aws_eip" "minecraft" {
  count = var.assign_elastic_ip ? 1 : 0

  domain = "vpc"
  tags   = { Name = "${var.project_name}-eip" }
}

resource "aws_eip_association" "minecraft" {
  count = var.assign_elastic_ip ? 1 : 0

  allocation_id = aws_eip.minecraft[0].id
  instance_id   = aws_instance.minecraft_beta.id
}

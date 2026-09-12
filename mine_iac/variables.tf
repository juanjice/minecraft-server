variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "minecraft"
}

variable "availability_zone" {
  type    = string
  default = "us-east-1a"
}

variable "subnet_cidr" {
  type    = string
  default = "172.31.0.16/28"
}

variable "instance_type" {
  type    = string
  default = "t4g.medium"
}

variable "ami_name_filter" {
  type    = string
  default = "ubuntu/images/hvm-ssd-gp3/ubuntu-resolute-26.04-arm64-server-*"
}

variable "root_volume_size" {
  type    = number
  default = 20
}

variable "assign_elastic_ip" {
  type    = bool
  default = true
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/minecraft_server.pub"
}

variable "ssh_allowed_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "minecraft_allowed_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "minecraft_version" {
  type    = string
  default = "1.21.11"
}

variable "java_package" {
  type    = string
  default = "openjdk-21-jre-headless"
}

variable "java_xms" {
  type    = string
  default = "2600M"
}

variable "java_xmx" {
  type    = string
  default = "2600M"
}

variable "server_port" {
  type    = number
  default = 25565
}

variable "rcon_port" {
  type    = number
  default = 25575
}

variable "motd" {
  type    = string
  default = "Servidor de Minecraft"
}

variable "max_players" {
  type    = number
  default = 12
}

variable "gamemode" {
  type    = string
  default = "survival"
}

variable "difficulty" {
  type    = string
  default = "easy"
}

variable "level_seed" {
  type    = string
  default = ""
}

variable "view_distance" {
  type    = number
  default = 10
}

variable "simulation_distance" {
  type    = number
  default = 8
}

variable "spawn_protection" {
  type    = number
  default = 0
}

variable "pause_when_empty_seconds" {
  type    = number
  default = 60
}

variable "whitelist_enabled" {
  type    = bool
  default = true
}

variable "online_mode" {
  type    = bool
  default = false
}

variable "enable_command_block" {
  type    = bool
  default = false
}

variable "whitelist_players" {
  type    = list(string)
  default = []
}

variable "op_players" {
  type    = list(string)
  default = []
}

variable "swap_size_mb" {
  type    = number
  default = 2048
}

variable "timezone" {
  type    = string
  default = "America/Bogota"
}

variable "backup_dir" {
  type    = string
  default = "/var/backups/minecraft"
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "backup_schedule" {
  type    = string
  default = "04:30"
}

variable "minecraft_dir" {
  type    = string
  default = "/opt/minecraft"
}

variable "minecraft_user" {
  type    = string
  default = "minecraft"
}

variable "enable_scheduled_start" {
  type    = bool
  default = false
}

variable "enable_scheduled_stop" {
  type    = bool
  default = true
}

variable "start_time" {
  type    = string
  default = "17:00"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.start_time))
    error_message = "start_time debe ser HH:MM en formato de 24 horas, por ejemplo 17:00."
  }
}

variable "stop_time" {
  type    = string
  default = "02:00"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.stop_time))
    error_message = "stop_time debe ser HH:MM en formato de 24 horas, por ejemplo 02:00."
  }
}

variable "schedule_days" {
  type    = string
  default = "*"

  validation {
    condition     = can(regex("^(\\*|(MON|TUE|WED|THU|FRI|SAT|SUN)(-(MON|TUE|WED|THU|FRI|SAT|SUN))?(,(MON|TUE|WED|THU|FRI|SAT|SUN)(-(MON|TUE|WED|THU|FRI|SAT|SUN))?)*)$", var.schedule_days))
    error_message = "schedule_days debe ser * o dias en ingles abreviado, por ejemplo FRI-SUN o MON,WED,FRI."
  }
}

variable "idle_stop_minutes" {
  type    = number
  default = 20

  validation {
    condition     = var.idle_stop_minutes == 0 || var.idle_stop_minutes >= 5
    error_message = "idle_stop_minutes debe ser 0 (desactivado) o al menos 5, para dar tiempo a que el servidor arranque."
  }
}

variable "monthly_budget_usd" {
  type    = number
  default = 15
}

variable "budget_alert_emails" {
  type    = list(string)
  default = []
}

variable "budget_filter_by_project_tag" {
  type    = bool
  default = false
}

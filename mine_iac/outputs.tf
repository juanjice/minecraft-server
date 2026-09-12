output "instance_id" {
  value = aws_instance.minecraft_beta.id
}

output "public_ip" {
  description = "IP publica del servidor. Fija si assign_elastic_ip = true."
  value       = var.assign_elastic_ip ? aws_eip.minecraft[0].public_ip : aws_instance.minecraft_beta.public_ip
}

output "minecraft_address" {
  description = "Lo que los jugadores escriben en Multijugador > Agregar servidor."
  value       = "${var.assign_elastic_ip ? aws_eip.minecraft[0].public_ip : aws_instance.minecraft_beta.public_ip}:${var.server_port}"
}

output "ssh_command" {
  value = "ssh -i ${replace(var.ssh_public_key_path, ".pub", "")} ubuntu@${var.assign_elastic_ip ? aws_eip.minecraft[0].public_ip : aws_instance.minecraft_beta.public_ip}"
}

output "rcon_tunnel_command" {
  description = "Tunel SSH para usar RCON desde la maquina local sin exponer el puerto."
  value       = "ssh -i ${replace(var.ssh_public_key_path, ".pub", "")} -N -L ${var.rcon_port}:127.0.0.1:${var.rcon_port} ubuntu@${var.assign_elastic_ip ? aws_eip.minecraft[0].public_ip : aws_instance.minecraft_beta.public_ip}"
}

output "power_schedule" {
  description = "Encendido y apagado automaticos."
  value = format(
    "encendido programado: %s | apagado programado: %s | apagado por inactividad: %s",
    var.enable_scheduled_start ? "${var.start_time} ${var.timezone}, dias ${var.schedule_days}" : "no",
    var.enable_scheduled_stop ? "${var.stop_time} ${var.timezone}, dias ${var.schedule_days}" : "no",
    var.idle_stop_minutes > 0 ? "${var.idle_stop_minutes} min sin jugadores" : "no",
  )
}

output "start_url" {
  description = "Enlace para encender el servidor. Compartir solo con los jugadores."
  value       = "${aws_lambda_function_url.start_link.function_url}?token=${random_password.start_token.result}"
  sensitive   = true
}

output "budget_alert" {
  value = length(var.budget_alert_emails) > 0 ? format("USD %s/mes, avisos a %d correo(s)", var.monthly_budget_usd, length(var.budget_alert_emails)) : "desactivada: falta budget_alert_emails"
}

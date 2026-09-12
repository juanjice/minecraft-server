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
  description = "Horario de encendido y apagado automatico."
  value = var.enable_power_schedule ? format(
    "enciende %s / apaga %s (%s), dias: %s",
    var.start_time, var.stop_time, var.timezone, var.schedule_days
  ) : "desactivado"
}

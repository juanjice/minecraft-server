# Manual de operacion del servidor

Todo lo que se hace con el servidor una vez creado: entrar, agregar gente, respaldar, actualizar y resolver problemas. No hace falta saber Terraform para nada de esto.

Antes de empezar, configura un presupuesto en AWS. El servidor genera costos mientras está encendido, y un error de configuración puede dispararlos sin aviso. AWS Budgets permite definir un tope mensual en dólares y recibir una alerta por correo al alcanzar cierto porcentaje del límite. Si no sabes cómo hacerlo, pide ayuda a alguien de TI o consúltalo con un asistente de IA; toma unos minutos y evita sorpresas en la factura.

Para levantar o modificar la infraestructura, ver [README.md](README.md).

---

## 1. Datos del servidor

**Direccion para los jugadores:** la IP publica seguida de `:25565`, por ejemplo
`203.0.113.25:25565`.

Es una IP elastica, o sea fija: se consulta una vez y no vuelve a cambiar aunque
la maquina se apague y se prenda. Dos formas de verla:

- En la consola de AWS: EC2 > Instances > `minecraft-beta` > columna *Public
  IPv4 address*.
- Con Terraform, desde `mine_iac/`: `terraform output minecraft_address`.

En el juego: **Multijugador > Agregar servidor**, y ahi se pega la direccion.

**Version:** Minecraft Java Edition 1.21.11. Los jugadores tienen que usar
exactamente esa version del cliente.

**Whitelist activa.** Quien no este en la lista no entra, aunque conozca la IP.

---

## 2. Horario: el servidor se prende y se apaga solo

Para no pagar una maquina encendida cuando nadie juega, hay un horario automatico:

| | |
|---|---|
| Se prende | 17:00 |
| Se apaga | 02:00 |
| Zona horaria | America/Bogota |
| Dias | todos |

Entre las 02:00 y las 17:00 el servidor esta apagado y no responde. Eso es normal,
no es una falla.

Cuando se apaga, el mundo se guarda automaticamente antes de que la maquina muera.
Lo que no hay es aviso previo: quien este jugando a las 02:00 se cae de golpe.

### Prenderlo fuera de horario

Desde la consola de AWS: EC2 > Instances > seleccionar `minecraft-beta` >
*Instance state* > **Start instance**. Queda jugable unos 2 minutos despues.

Con la AWS CLI:

```bash
aws ec2 start-instances --instance-ids <ID-de-la-instancia>
aws ec2 stop-instances  --instance-ids <ID-de-la-instancia>
```

El ID se ve en la consola, o con `terraform output instance_id`.

Prenderla a mano no cambia el horario: se va a apagar igual a las 02:00.

### Cambiar el horario

Se edita `mine_iac/prod.tfvars` y se aplica. Esto si requiere Terraform:

```hcl
start_time    = "15:00"
stop_time     = "01:00"
schedule_days = "FRI-SUN"    # solo viernes, sabado y domingo
timezone      = "America/Bogota"
```

```bash
cd mine_iac && terraform apply -var-file=prod.tfvars
```

Es un cambio barato: solo toca las reglas del horario, no reinicia nada.

Para dejar el servidor encendido permanentemente,
`enable_power_schedule = false`. Ojo: eso desactiva tambien el apagado, asi que
la maquina se queda prendida cobrando hasta que alguien la apague a mano.

---

## 3. Entrar a la maquina

```bash
ssh -i ~/.ssh/minecraft_server ubuntu@<IP>
```

La llave privada es `~/.ssh/minecraft_server` y tiene que estar en modo 600
(`chmod 600 ~/.ssh/minecraft_server`). El usuario siempre es `ubuntu`.

Si la maquina esta apagada por el horario, la conexion falla. Hay que prenderla
primero.

---

## 4. Tareas comunes

Todas se ejecutan dentro de la maquina, por SSH. `mc-cmd` manda comandos a la
consola del servidor sin interrumpir la partida de nadie.

### Agregar a alguien a la whitelist

```bash
sudo mc-cmd "whitelist add Pepe"
```

Queda efectivo de inmediato, no hay que reiniciar. Para quitarlo,
`whitelist remove Pepe`. Para ver la lista completa, `whitelist list`.

Conviene agregar el nombre tambien en `mine_iac/prod.tfvars`, en
`whitelist_players`. No afecta al servidor actual, pero si algun dia se recrea la
maquina, la lista nace completa.

### Dar o quitar operador

```bash
sudo mc-cmd "op Pepe"
sudo mc-cmd "deop Pepe"
```

Un operador puede usar comandos de administracion dentro del juego. Darlo con
criterio.

### Ver quien esta conectado y hablarles

```bash
sudo mc-cmd "list"
sudo mc-cmd "say Nos vemos en 10 minutos"
```

### Expulsar o banear

```bash
sudo mc-cmd "kick Pepe Comportate"
sudo mc-cmd "ban Pepe"
sudo mc-cmd "pardon Pepe"
```

### Reiniciar el servidor

```bash
sudo systemctl restart minecraft
```

Guarda el mundo antes de bajar. Tarda entre 30 y 60 segundos en volver.

### Ver la consola en vivo

```bash
sudo journalctl -u minecraft -f
```

`Ctrl+C` para salir. Esto no detiene el servidor.

### Cambiar opciones del juego

Las opciones viven en `/opt/minecraft/server.properties`:

```bash
sudo -u minecraft nano /opt/minecraft/server.properties
sudo systemctl restart minecraft
```

Las mas pedidas: `difficulty`, `max-players`, `motd` (el texto que aparece en la
lista de servidores), `view-distance`, `pvp`.

Hay una opcion que conviene conocer: `pause-when-empty-seconds=60`. Hace que el
servidor deje de procesar el mundo cuando no hay nadie conectado, lo que ahorra
CPU. El efecto secundario es que las granjas automaticas y la redstone tampoco
avanzan con el servidor vacio. Con `-1` se desactiva.

---

## 5. Respaldos

Hay un respaldo automatico **todos los dias a las 04:30** que conserva los
ultimos 7 dias. Se guardan en `/var/backups/minecraft/`.

```bash
ls -lh /var/backups/minecraft/      # ver los respaldos disponibles
sudo mc-backup                      # hacer uno ahora mismo
```

El respaldo manual se puede correr con jugadores conectados: el servidor deja de
escribir en disco mientras se empaqueta y luego sigue normal.

Advertencia importante: los respaldos quedan en el mismo disco del servidor. Eso
protege contra un accidente dentro del juego o un mundo corrupto, pero **no**
contra perder la maquina. Para algo importante, bajarlo a otro lado:

```bash
# desde la maquina local
scp -i ~/.ssh/minecraft_server ubuntu@<IP>:/var/backups/minecraft/world-*.tar.gz .
```

### Restaurar un respaldo

```bash
sudo systemctl stop minecraft
cd /opt/minecraft
sudo mv world world-roto                       # por si acaso
sudo -u minecraft tar -xzf /var/backups/minecraft/world-AAAAMMDD-HHMMSS.tar.gz
sudo chown -R minecraft:minecraft /opt/minecraft
sudo systemctl start minecraft
```

### Migrar el mundo de otro servidor

Sirve para traer el mundo de un servidor anterior. Se asume un `.tar.gz` de la
carpeta del servidor; si la estructura interna es distinta, hay que ajustar las
rutas.

```bash
# desde la maquina local
scp -i ~/.ssh/minecraft_server respaldo.tar.gz ubuntu@<IP>:/tmp/

# dentro de la maquina
sudo systemctl stop minecraft
sudo tar -xzf /tmp/respaldo.tar.gz -C /tmp
sudo cp -r /tmp/minecraft/world /tmp/minecraft/world_nether /tmp/minecraft/world_the_end \
           /opt/minecraft/
sudo cp -r /tmp/minecraft/plugins/. /opt/minecraft/plugins/
sudo chown -R minecraft:minecraft /opt/minecraft
sudo systemctl start minecraft
```

No copiar el `server.properties` viejo: trae el password de RCON del servidor
anterior y puede traer opciones invalidas. La whitelist y los operadores ya
vienen sembrados desde `prod.tfvars`.

---

## 6. Actualizar el servidor

```bash
sudo mc-update
```

Hace un respaldo, baja la ultima version estable de Paper para 1.21.11 y reinicia.
Si algo sale mal, el respaldo quedo en `/var/backups/minecraft/`.

Para saltar a otra version de Minecraft (por ejemplo 1.22) hay que cambiar
`minecraft_version` en `mine_iac/prod.tfvars` y editar `/etc/minecraft/minecraft.env`
en la maquina. Antes de hacerlo, verificar que los plugins instalados sean
compatibles con la version nueva, y hacer un respaldo aparte.

---

## 7. Plugins

Los plugins van en `/opt/minecraft/plugins/` como archivos `.jar`:

```bash
sudo -u minecraft curl -L -o /opt/minecraft/plugins/NombrePlugin.jar "<URL-del-jar>"
sudo systemctl restart minecraft
```

La URL tiene que apuntar al archivo `.jar`, no a la pagina web del plugin. Bajar
`https://essentialsx.net/` descarga la pagina, no el plugin. Los enlaces buenos
estan en la seccion de descargas de Modrinth o en los *releases* de GitHub del
proyecto.

Si se migro la carpeta `plugins` de un servidor anterior, los plugins que tuviera
ya estan ahi. Paper ademas incluye `spark`, que sirve para medir rendimiento
(`/spark profiler` dentro del juego).

---

## 8. Si algo se rompe

### "No me conecta" / "Connection timed out"

1. Revisar la hora. Entre 02:00 y 17:00 la maquina esta apagada a proposito
   (seccion 2).
2. Si deberia estar prendida, confirmar en la consola de AWS que el estado sea
   *running*.
3. Si acaba de prenderse, esperar 2 minutos: el servidor tarda en arrancar.
4. Ya dentro de la maquina: `sudo systemctl status minecraft`.

### "Connection refused"

La maquina esta prendida pero el servidor de Minecraft no esta corriendo.

```bash
sudo systemctl status minecraft
sudo journalctl -u minecraft -n 100 --no-pager    # ultimas 100 lineas
sudo systemctl start minecraft
```

### "Me saca al entrar" / "You are not white-listed"

El nombre no esta en la whitelist, o esta escrito distinto (mayusculas incluidas).

```bash
sudo mc-cmd "whitelist list"
sudo mc-cmd "whitelist add Pepe"
```

### "Version incompatible"

El cliente tiene que ser 1.21.11 exacto.

### El juego se siente con tirones

```bash
sudo mc-cmd "tps"     # 20 es lo ideal; por debajo de 18 ya se nota
```

Si los TPS estan bien pero igual se siente mal, es red, no servidor. Si estan
bajos, las causas tipicas son demasiadas entidades (mobs acumulados, granjas), un
plugin pesado, o que la instancia se quedo sin credito de CPU. Lo primero se
diagnostica con `/spark profiler` dentro del juego; lo ultimo, en CloudWatch con
la metrica `CPUCreditBalance`.

### El servidor se reinicia solo

Casi siempre es falta de memoria. Revisar:

```bash
free -h
sudo journalctl -u minecraft | grep -i -E 'out of memory|killed'
```

Si aparece seguido, toca subir la instancia a `t4g.large`. Es un cambio en
`mine_iac/prod.tfvars` y **recrea la maquina**, asi que hay que respaldar y
restaurar el mundo.

### Se lleno el disco

```bash
df -h /
sudo du -sh /opt/minecraft/* /var/backups/minecraft
```

Lo que suele crecer son los respaldos y el mundo. Se pueden borrar respaldos
viejos a mano; los de mas de 7 dias se borran solos.

### El servidor nuevo no arranco nunca

Si la maquina se acaba de crear y nunca funciono, el problema esta en el script de
instalacion:

```bash
sudo tail -100 /var/log/cloud-init-output.log
ls -l /var/lib/minecraft-bootstrap-done     # si existe, el script termino bien
```

### Se perdio la llave SSH

No hay forma de entrar. La llave no se puede recuperar ni reemplazar en una
instancia existente. Queda respaldar el volumen desde la consola de AWS y recrear
la maquina. Para que esto no vuelva a pasar, ver la mejora 5 del
[README.md](README.md), que habilita acceso por consola sin llaves.

---

## 9. Referencia rapida

```bash
# Conexion
ssh -i ~/.ssh/minecraft_server ubuntu@<IP>

# Estado
sudo systemctl status minecraft
sudo journalctl -u minecraft -f

# Control
sudo systemctl restart minecraft
sudo systemctl stop minecraft
sudo systemctl start minecraft

# Jugadores
sudo mc-cmd "list"
sudo mc-cmd "whitelist add Pepe"
sudo mc-cmd "op Pepe"
sudo mc-cmd "say mensaje"

# Respaldos
sudo mc-backup
ls -lh /var/backups/minecraft/

# Mantenimiento
sudo mc-update
df -h /
free -h
```

Cualquier comando de la consola de Minecraft funciona dentro de `mc-cmd`, entre
comillas y sin la barra inicial: `sudo mc-cmd "time set day"`,
`sudo mc-cmd "weather clear"`, `sudo mc-cmd "difficulty peaceful"`.

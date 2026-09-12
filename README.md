# Servidor de Minecraft en AWS (Terraform)

IaC para levantar un servidor de Minecraft Java Edition (PaperMC) sobre una sola
instancia EC2, lista para jugar en cuanto termina de arrancar: Java instalado,
servidor descargado, puerto abierto, whitelist sembrada, RCON configurado y
autoarranque con systemd.

No hay soporte para LocalStack. LocalStack no emula el arranque real de una EC2
(no ejecuta `user_data`, no hay cloud-init, no hay red de verdad), asi que todo
lo que importa en este proyecto es justamente lo que no se puede probar ahi. Se
trabaja directo contra la nube.

Este documento cubre la **infraestructura**: que se crea en AWS y por que. La
operacion del dia a dia (entrar al servidor, whitelist, respaldos, horarios,
que hacer si algo falla) esta en [OPERACION.md](OPERACION.md), escrito para
quien administra el servidor sin tener que tocar Terraform.

---

## 1. Requisitos

- Terraform >= 1.6
- AWS CLI con un perfil valido (`aws sts get-caller-identity` debe responder)
- Una llave SSH (ver seccion 4)

La configuracion propia de cada servidor no esta en el repositorio. Se parte de
las plantillas:

```bash
cd mine_iac
cp .env.example          .env          # perfil de AWS
cp prod.tfvars.example   prod.tfvars   # region, tamaño, jugadores, horarios
```

`.env` y `prod.tfvars` estan en `.gitignore`. Ahi van el perfil de AWS, los
nombres de los jugadores y los CIDR con acceso: nada de eso tiene por que ser
publico. Terraform lee automaticamente cualquier variable de entorno con prefijo
`TF_VAR_`.

El despliegue esta en la seccion 6.

---

## 2. Archivos

| Archivo | Contenido |
|---|---|
| `terraform.tf` | Version de Terraform y del provider |
| `provider.tf` | Provider AWS, region y tags por defecto |
| `variables.tf` | Todas las variables con sus valores por defecto |
| `network.tf` | Subnet, tabla de rutas, security group |
| `main.tf` | AMI, llave SSH, instancia, IP elastica |
| `scheduler.tf` | Horario de encendido y apagado, y su rol de IAM |
| `outputs.tf` | IP publica, direccion para los jugadores, comandos SSH |
| `prod.tfvars.example` | Plantilla de configuracion, se copia a `prod.tfvars` |
| `.env.example` | Plantilla del perfil de AWS, se copia a `.env` |
| `templates/user_data.sh.tftpl` | Script de arranque que configura la maquina |

Todo vive en `mine_iac/`. El manual de operacion es `OPERACION.md`, en la raiz.

---

## 3. Decisiones de infraestructura

Aqui quedan explicadas las razones que antes estaban como comentarios sueltos en
los `.tf`.

### AMI (`data.aws_ami.ubuntu`)

Es el sistema operativo donde vive el servidor. Se usa Ubuntu Server publicado
por Canonical (owner `099720109477`), que es la opcion con mas documentacion y
paquetes al dia para este caso. Cualquier otro SO sirve, pero entonces hay que
reescribir el bootstrap, porque todo el script asume `apt` y `systemd`.

El filtro apunta a la variante **arm64**, que es obligatoria porque la instancia
es de la familia Graviton (`t4g`). Una AMI `amd64` simplemente no arranca ahi.

### Region (`var.aws_region`)

`us-east-1` es la de menor latencia desde Colombia y la mas barata. Se puede
cambiar, pero entonces hay que ajustar tambien `availability_zone` y revisar que
el CIDR de la subnet siga siendo valido en esa VPC.

### Tipo de instancia (`t4g.medium`)

El corazon del servidor. `t4g.medium` son 2 vCPU ARM y 4 GiB de RAM:

- Mas abajo (`t4g.small`, 2 GiB) el servidor funciona, pero la JVM queda sin
  margen y la maquina se cae por memoria de forma esporadica. Es exactamente el
  problema que tenia el montaje anterior, que corria con `-Xmx1400M`.
- Mas arriba (`t4g.large`, 8 GiB) vale la pena si entran muchos jugadores, se
  suben plugins pesados o se amplia el `view-distance`.

Las instancias `t` son **burstable**: acumulan credito de CPU cuando estan
tranquilas y lo gastan cuando el servidor trabaja. El state actual muestra
`cpu_credits = unlimited`, lo que significa que si el credito se agota AWS sigue
dando CPU y lo cobra aparte. Hay que tenerlo en cuenta en la factura.

### Volumen raiz (`root_block_device`)

`gp3` es SSD de uso general. No es opcional: `t4g.medium` es EBS-only, no tiene
disco local, asi que el volumen raiz es el unico almacenamiento que existe.

20 GiB alcanzan de sobra para el servidor, los mundos y una semana de respaldos.
`encrypted = true` cifra el volumen en reposo con la llave KMS por defecto de la
cuenta; no tiene costo extra ni impacto de rendimiento medible.

`delete_on_termination = true` significa que el mundo se borra si se destruye la
instancia. Esta bien mientras el servidor sea desechable; cuando el mundo empiece
a importar, ver la mejora 2 de la seccion 8.

### Ciclo de vida (`lifecycle`)

`ignore_changes = [ami]` es lo mas importante del archivo. `most_recent = true`
en el data source hace que la AMI cambie cada vez que Canonical publica una
imagen nueva, y la AMI es un atributo que fuerza reemplazo: sin este ignore, un
`apply` rutinario destruiria la instancia y el mundo con ella.

`ignore_changes = [user_data]` evita diffs fantasma. `user_data` solo se ejecuta
en el **primer** arranque de la maquina, asi que cambiar una variable del
bootstrap despues de creada no tiene ningun efecto sobre el servidor que ya esta
corriendo. Sin este ignore, Terraform reportaria un cambio que en realidad no
hace nada.

`user_data_replace_on_change = false` es el seguro de vida: con `true`, editar
cualquier opcion del bootstrap recrearia la instancia y borraria el mundo.

No hay `prevent_destroy`. Mientras el mundo viva en el volumen raiz, ese flag da
una falsa sensacion de seguridad: bloquea `terraform destroy`, pero no protege
contra lo unico que de verdad borra el mundo, que es un reemplazo de la instancia.
La proteccion real es sacar el mundo a un volumen aparte (seccion 8, mejora 1) y,
mientras eso no este, los respaldos diarios.

### Red (`network.tf`)

La subnet vive en la VPC por defecto de la cuenta, con `map_public_ip_on_launch`
para que la instancia sea alcanzable desde internet.

Se crea una **tabla de rutas propia** con salida `0.0.0.0/0` hacia el Internet
Gateway de la VPC. Antes la subnet dependia implicitamente de la tabla de rutas
principal de la VPC por defecto, que trae esa ruta de fabrica. Funcionaba, pero
era una dependencia invisible: si alguien toca esa tabla, el bootstrap falla sin
explicacion aparente, porque la maquina no puede descargar Java ni el jar de
Paper. Ahora la ruta es explicita y el `depends_on` de la instancia garantiza que
exista antes de arrancar.

### Security group

Es el firewall real de la instancia. Solo dos puertas de entrada:

| Puerto | Protocolo | Desde | Para que |
|---|---|---|---|
| 22 | TCP | `ssh_allowed_cidrs` | Administracion por SSH |
| 25565 | TCP | `minecraft_allowed_cidrs` | Minecraft Java Edition |

El **25575 (RCON) no se expone**. RCON es una consola remota sin cifrado: quien
llega al puerto y tiene el password ejecuta cualquier comando del servidor. Se
usa solo desde dentro de la maquina (`127.0.0.1`) o por un tunel SSH
(`terraform output rcon_tunnel_command`).

Minecraft Java Edition es TCP puro; no hace falta abrir UDP. Bedrock si usa UDP
19132, y habria que agregar esa regla mas un puente como GeyserMC.

Sobre "abrir el puerto de Minecraft": son dos capas y solo una requiere trabajo.
El security group es la que filtra de verdad. El firewall del sistema operativo
(`ufw`) viene **inactivo** en las AMI de Ubuntu, asi que no hay nada que abrir
dentro de la maquina. Si algun dia se activa `ufw`, hay que acordarse de permitir
22 y 25565 ahi tambien.

### IP elastica (`aws_eip`)

Sin esto, la IP publica cambia cada vez que la instancia se apaga y se prende, y
hay que avisarle la nueva a todos los jugadores. Con la IP elastica la direccion
es fija.

Desde 2024 AWS cobra toda IPv4 publica por igual (unos USD 0.005/hora), asi que
una IP elastica asociada a una instancia encendida cuesta lo mismo que la IP
automatica que ya se estaba pagando. No hay razon para no usarla. Lo unico que se
paga aparte es una IP elastica reservada y sin usar.

### Horario de encendido y apagado (`scheduler.tf`)

Dos reglas de EventBridge Scheduler prenden y apagan la instancia a hora fija.
Es la palanca de ahorro mas grande del proyecto: un servidor que solo esta
encendido 9 horas al dia cuesta menos de la mitad (seccion 7).

| Variable | Default | Que hace |
|---|---|---|
| `start_time` | `17:00` | Hora de encendido, formato `HH:MM` de 24 horas |
| `stop_time` | `02:00` | Hora de apagado |
| `timezone` | `America/Bogota` | Zona horaria de los horarios y del sistema operativo |
| `schedule_days` | `*` | Dias en que aplica: `*`, o `FRI-SUN`, o `MON,WED,FRI` |
| `enable_power_schedule` | `true` | `false` deja las reglas creadas pero en estado `DISABLED` |

Las horas se escriben como `HH:MM` y Terraform arma la expresion cron, para no
tener que pensar en el formato de 6 campos de AWS. `17:00` se convierte en
`cron(0 17 * * ? *)`.

Se usa **EventBridge Scheduler** y no una regla clasica de EventBridge ni un cron
dentro de la maquina, por dos razones concretas:

- Scheduler acepta zona horaria IANA nativa
  (`schedule_expression_timezone = "America/Bogota"`). No hay que traducir a UTC
  a mano ni acordarse de los cambios de horario.
- Un cron dentro de la maquina puede apagarla, pero no puede volver a prenderla:
  cuando llega la hora de encender, no hay nadie ejecutando nada.

El destino es un *universal target*
(`arn:aws:scheduler:::aws-sdk:ec2:stopInstances`), que llama la API de EC2
directamente sin una Lambda intermedia. El rol de IAM asociado solo puede
arrancar y detener **esa** instancia, y su politica de confianza esta restringida
a esta cuenta para evitar el problema del diputado confundido.

El mundo no se pierde al apagar. Un stop de EC2 es un apagado ACPI ordenado: el
sistema baja systemd, systemd ejecuta el `ExecStop` del servicio y `mc-stop`
guarda el mundo por RCON antes de que el proceso muera. AWS da unos minutos de
gracia antes de forzar el corte, y `TimeoutStopSec=120` cabe en esa ventana. Lo
que si pasa es que los jugadores conectados se caen sin aviso previo.

### Metadatos (`metadata_options`)

`http_tokens = "required"` obliga IMDSv2. Bloquea la clase de ataque en la que
una peticion forjada desde la aplicacion lee los metadatos de la instancia y se
roba las credenciales del rol de IAM. Ya estaba activo por defecto; queda
explicito para que no dependa del default del provider.

---

## 4. La llave SSH

La llave **se genera en la maquina local** y Terraform solo sube la parte
publica. Asi la llave privada nunca pasa por Terraform ni queda escrita en
`terraform.tfstate`, que es un archivo de texto plano sin cifrar.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/minecraft_server -C "minecraft-server"
```

Eso produce dos archivos:

- `~/.ssh/minecraft_server` — llave privada, se queda en la maquina local
- `~/.ssh/minecraft_server.pub` — llave publica, es la que apunta
  `var.ssh_public_key_path` y la que sube a AWS

Si se prefiere un archivo con extension y formato `.pem` clasico:

```bash
ssh-keygen -t rsa -b 4096 -m PEM -f ~/.ssh/minecraft_server.pem
```

El `.pem` no tiene nada de especial: es solo el nombre que le pone AWS al archivo
cuando es **AWS** quien genera la llave. Para conectarse, `ssh -i` acepta igual
una llave OpenSSH sin extension. ed25519 es mas corta, mas rapida y mas segura
que RSA, y EC2 la soporta sin problema, asi que es la recomendada.

La llave privada debe quedar en modo 600, o SSH la rechaza:

```bash
chmod 600 ~/.ssh/minecraft_server
```

Conexion (el comando exacto lo imprime `terraform output ssh_command`):

```bash
ssh -i ~/.ssh/minecraft_server ubuntu@<IP>
```

El usuario es `ubuntu` porque asi viene configurado en las AMI de Canonical. El
usuario `minecraft` que corre el servidor no tiene shell de login: no se puede
entrar con el, a proposito.

### Por que no generar la llave con Terraform

Se puede, con `tls_private_key` mas `local_sensitive_file`, y queda comodo en un
solo `apply`. El problema es que la llave privada termina guardada en
`terraform.tfstate` en texto plano. Con el state en disco local es un archivo mas
que proteger; con el state en S3 es una llave privada en un bucket. No vale la
pena por ahorrarse un `ssh-keygen`.

---

## 5. Que hace el bootstrap

`templates/user_data.sh.tftpl` lo ejecuta cloud-init como root, una sola vez, en
el primer arranque. Tarda entre 3 y 6 minutos.

Para seguirlo en vivo:

```bash
ssh -i ~/.ssh/minecraft_server ubuntu@<IP> 'sudo tail -f /var/log/cloud-init-output.log'
```

Cuando termina deja la marca `/var/lib/minecraft-bootstrap-done`.

1. **Sistema base.** Fija la zona horaria (`America/Bogota`, para que los logs y
   el timer de respaldos cuadren con la hora local) e instala `curl`, `jq`,
   `openssl`, `gcc` y Java. Se instala `openjdk-21-jre-headless`, no el JDK
   completo: el servidor solo necesita ejecutar, no compilar, y `headless` se
   ahorra las dependencias graficas. Paper 1.21.x requiere Java 21 o superior. Si
   el paquete no existe en esa version de Ubuntu, cae a `default-jre-headless`.

2. **Swap.** Crea 2 GiB de swap y baja `vm.swappiness` a 10. Es la red de
   seguridad contra el OOM killer: ante un pico de memoria el kernel pagina en
   disco en vez de matar el servidor. Con `swappiness=10` casi no se usa en
   operacion normal, solo cuando de verdad hace falta.

3. **Usuario de servicio.** Crea el usuario de sistema `minecraft` con home en
   `/opt/minecraft` y sin shell de login. El servidor no corre como root ni como
   `ubuntu`: si alguien explota una vulnerabilidad de un plugin, queda encerrado
   en una cuenta sin privilegios.

4. **Configuracion compartida.** Escribe `/etc/minecraft/minecraft.env` con las
   rutas y puertos. Todos los scripts auxiliares lo leen de ahi, asi que no hay
   rutas duplicadas por ningun lado.

5. **Password de RCON.** Lo genera la propia maquina con
   `openssl rand -hex 24` y lo guarda en `/etc/minecraft/rcon.env` con permisos
   `0640 root:minecraft`. No se pasa por variable de Terraform, no queda en el
   state, no queda en el repositorio y no se imprime en el log (el `set -x` del
   script se apaga alrededor de esa parte). En el montaje anterior el password
   estaba escrito en `server.properties` y viajo al backup del repositorio.

6. **mcrcon.** Se compila desde el fuente de `Tiiffi/mcrcon` porque no esta
   empaquetado en Ubuntu. Son dos comandos y un binario de 30 KB. RCON es el
   protocolo que permite mandarle comandos a la consola del servidor sin estar
   dentro de la sesion del proceso, y es la pieza que hace posible el apagado
   ordenado y los respaldos en caliente.

7. **Scripts de operacion** en `/usr/local/bin`:

   - `mc-cmd "<comando>" ...` — manda comandos a la consola por RCON
   - `mc-stop` — avisa en el chat, guarda el mundo y detiene; lo usa systemd
   - `mc-backup` — respaldo comprimido de los tres mundos con rotacion
   - `mc-update` — baja el ultimo build estable de Paper para la version fijada

8. **server.jar.** Consulta la API de PaperMC
   (`fill.papermc.io/v3`), filtra el ultimo build del canal `STABLE` para la
   version configurada y lo descarga. Asi no hay URLs quemadas que se vencen.
   Se usa Paper y no el servidor vanilla porque rinde bastante mas y acepta
   plugins de Bukkit/Spigot.

9. **EULA.** Escribe `eula=true`. Sin esto el servidor arranca, escribe el
   archivo y se cierra de inmediato.

10. **server.properties.** Se genera desde las variables de Terraform. Solo se
    escriben las opciones que interesan; Paper completa el resto con sus valores
    por defecto en el primer arranque. Detalles que vale la pena conocer:

    - `white-list` y `enforce-whitelist`: la primera activa la lista, la segunda
      expulsa en el momento a quien ya este conectado y no figure en ella.
    - `online-mode=false` desactiva la verificacion contra los servidores de
      Mojang. Es lo que estaba configurado antes y permite entrar con clientes
      no oficiales. Ver el riesgo en la seccion 8, mejora 6.
    - `enforce-secure-profile` se deriva de `online_mode`. En modo offline no
      existe perfil firmado, asi que dejarlo en `true` produce expulsiones al
      entrar o al escribir en el chat. La configuracion anterior tenia
      `ensure-secure-profile=false`, que **no es una opcion valida** de
      Minecraft: el nombre correcto es `enforce-secure-profile`, y la linea no
      hacia nada.
    - `pause-when-empty-seconds=60`: si no hay nadie conectado por un minuto, el
      servidor deja de procesar ticks. Baja el consumo de CPU a casi nada, que en
      una instancia burstable se traduce en credito acumulado. El costo es que
      las granjas automaticas y los circuitos de redstone tampoco corren con el
      servidor vacio. Con `-1` se desactiva.
    - `spawn-protection=0`: sin esto, un radio de 16 bloques alrededor del spawn
      queda bloqueado para todos los que no sean operadores. En un servidor
      privado entre amigos solo estorba.

11. **whitelist.json y ops.json.** Se siembran desde `var.whitelist_players` y
    `var.op_players`, sin necesidad de que el servidor este arriba. El UUID de
    cada jugador se resuelve segun el modo:

    - `online_mode = true`: se consulta la API de Mojang. Si un nombre no existe,
      se salta con un aviso en el log en vez de escribir basura en el archivo.
    - `online_mode = false`: el UUID es deterministico, version 3, calculado
      sobre `MD5("OfflinePlayer:<nombre>")`. Es exactamente lo que hace el
      servidor internamente en modo offline.

    Esto se verifico contra la `whitelist.json` real del servidor anterior: los
    10 UUID generados coinciden byte a byte con los que habia, y los 2
    operadores tambien.

    La alternativa era arrancar el servidor y mandar `whitelist add` por RCON,
    pero eso depende de que el servidor ya este escuchando y choca con
    `pause-when-empty-seconds`. Calcular el UUID no depende de nada.

    Para agregar gente despues, con el servidor corriendo:

    ```bash
    sudo mc-cmd "whitelist add Pepe" "whitelist reload"
    ```

12. **Flags de la JVM.** Quedan en `/opt/minecraft/jvm.args`, un argfile de Java,
    para que el unit de systemd se pueda leer. Son las flags de G1 de Aikar, la
    referencia practica para servidores de Minecraft: reducen las pausas de
    recoleccion de basura, que es lo que se siente como tirones dentro del juego.

    `-Xms` y `-Xmx` van iguales a proposito. Junto con `AlwaysPreTouch`, la JVM
    reserva y toca toda la memoria al arrancar, lo que evita el costo de ir
    creciendo el heap durante la partida. Reglas para ajustarlo:

    | Instancia | RAM | `java_xms` / `java_xmx` |
    |---|---|---|
    | `t4g.small` | 2 GiB | `1200M` |
    | `t4g.medium` | 4 GiB | `2600M` |
    | `t4g.large` | 8 GiB | `6G` |

    Nunca se le asigna toda la RAM de la maquina a la JVM: el heap es solo una
    parte del consumo del proceso (metaspace, hilos, buffers directos), y el
    sistema operativo tambien necesita memoria.

13. **systemd.** Es lo que responde a "configurar un autoinicio cada que se
    inicie la maquina". `systemctl enable` registra el servicio para que arranque
    en todo boot, y no hace falta `screen` ni `tmux` para nada:

    - `Restart=on-failure` con `RestartSec=20` lo levanta si se cae.
    - `SuccessExitStatus=0 143` evita que un apagado intencional (codigo 143 =
      SIGTERM) cuente como falla y dispare un reinicio.
    - `ExecStop=/usr/local/bin/mc-stop` guarda el mundo por RCON antes de
      detener. Sin esto, un `systemctl stop` o un reinicio de la maquina mata el
      proceso y se pierden los ultimos minutos de juego.
    - `TimeoutStopSec=120` le da tiempo a guardar mundos grandes.
    - `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=full` y compania encierran
      al proceso: solo puede escribir en `/opt/minecraft` y en el directorio de
      respaldos.

    Ademas queda un timer `minecraft-backup.timer` que corre `mc-backup` todos los
    dias a las 04:30 y conserva 7 dias. `Persistent=true` hace que se ejecute al
    encender si la maquina estaba apagada a esa hora.

14. **Marca de finalizacion** en `/var/lib/minecraft-bootstrap-done`.

---

## 6. Despliegue

Con `.env` y `prod.tfvars` ya copiados y editados (seccion 1):

```bash
source .env
terraform init
terraform plan  -var-file=prod.tfvars
terraform apply -var-file=prod.tfvars
```

Si ya hay una instancia creada a mano, no se puede adoptar: una llave SSH solo se
asigna en el momento de crear la instancia y `user_data` solo se ejecuta en el
primer arranque, asi que una maquina sin llave y sin bootstrap es inalcanzable
para siempre. Toca recrearla.

Al terminar, `terraform output` da la direccion para los jugadores y el comando
de conexion. El servidor tarda entre 3 y 6 minutos mas en quedar jugable,
mientras corre el bootstrap.

Para el dia a dia desde aqui, ver [OPERACION.md](OPERACION.md).

---

## 7. Costos aproximados (us-east-1)

| Concepto | Encendido 24/7 | Con horario 17:00-02:00 |
|---|---|---|
| `t4g.medium` on-demand | ~24.50 | ~9.20 |
| 20 GiB gp3 | ~1.60 | ~1.60 |
| IPv4 publica | ~3.65 | ~3.65 |
| **Total USD/mes** | **~30** | **~14.50** |

El disco y la IP se pagan igual con la maquina apagada: el volumen EBS existe
aunque nadie lo use, y una IP elastica sin instancia encendida tambien se cobra.
Lo unico que se deja de pagar es el computo, que es justamente la mayor parte.
Acortar la ventana o limitar `schedule_days` a los dias que de verdad se juega
baja mas la cifra.

La otra palanca es un Savings Plan de 1 año, que descuenta entre 30% y 40% del
computo. Ojo con combinarlas: un Savings Plan es un compromiso de gasto por hora
que se paga este la maquina encendida o no, asi que con un horario agresivo buena
parte del compromiso se desperdicia. Son estrategias alternativas, no
acumulativas. Verificar precios vigentes en la calculadora de AWS.

---

## 8. Mejoras propuestas, por prioridad

**1. Volumen EBS aparte para el mundo.** Es la mejora con mejor relacion
beneficio/esfuerzo. Hoy el mundo vive en el volumen raiz con
`delete_on_termination = true`, asi que recrear la instancia lo borra. Con un
`aws_ebs_volume` separado, montado en `/opt/minecraft` y con
`delete_on_termination = false`, la instancia vuelve a ser desechable: se puede
recrear para cambiar el bootstrap, subir de tipo o actualizar el SO sin tocar el
mundo. Resuelve de raiz la limitacion de "user_data solo corre una vez".

**2. Respaldos fuera de la maquina.** El timer actual escribe en el mismo volumen
EBS que protege: sirve contra un `/kill` desafortunado o corrupcion de chunks, no
contra perder la instancia. Lo correcto es subirlos a S3 con un rol de IAM
(`aws_iam_instance_profile`, permiso `s3:PutObject` sobre un solo prefijo) y una
regla de ciclo de vida que pase a Glacier a los 30 dias. Son unos centavos al
mes.

**3. Backend remoto para el state.** `terraform.tfstate` esta en disco local, sin
cifrado ni bloqueo. Si se borra esa carpeta, Terraform pierde el rastro de la
instancia y hay que reimportar todo a mano. Mover a S3 con versionado y bloqueo.
Mientras tanto, el `.gitignore` del repositorio ya evita que el state y el
tarball de 645 MB terminen en git.

**4. Restringir el acceso SSH.** `ssh_allowed_cidrs = ["0.0.0.0/0"]` deja el
puerto 22 expuesto a internet. La autenticacion es solo por llave (las AMI de
Ubuntu traen el password deshabilitado), asi que el riesgo real es bajo, pero no
hay motivo para regalar superficie:

```hcl
ssh_allowed_cidrs = ["TU.IP.PUBLICA/32"]
```

Si la IP del ISP cambia seguido, la alternativa es la mejora 5.

**5. AWS Systems Manager Session Manager.** Da shell sin abrir el puerto 22 y sin
llaves, via la consola o `aws ssm start-session`. Necesita un
`aws_iam_instance_profile` con la politica `AmazonSSMManagedInstanceCore`; el
agente ya viene instalado en las AMI de Ubuntu. Es ademas la salida de
emergencia cuando se pierde la llave privada.

**6. Revisar `online-mode`.** Con `online-mode=false` el servidor no verifica la
identidad contra Mojang, y la whitelist pasa a ser una lista de **nombres**, no
de cuentas: cualquiera que conozca uno de los 10 nombres de la lista puede entrar
haciendose pasar por ese jugador. Si todos tienen cuenta legitima, `true` cierra
ese hueco de una. Si se necesita seguir en offline, al menos acotar
`minecraft_allowed_cidrs` a las IP de los jugadores.

**7. Un nombre en vez de una IP.** Route53 cuesta USD 0.50/mes por zona y permite
`mc.tudominio.com`. Gratis, DuckDNS. Ademas desacopla a los jugadores de la
infraestructura: cambiar de instancia deja de implicar avisarle a todo el mundo.

**8. Plugins como codigo.** Hoy `plugins/` se llena a mano. Vale la pena bajarlos
en el bootstrap desde URLs versionadas (la API de Modrinth o los releases de
GitHub) para que una instancia nueva nazca completa. Ojo con lo que se intento la
vez pasada:

```bash
curl -L -o EssentialsX.jar "https://essentialsx.net/"   # descarga HTML, no un jar
```

Esas URLs son paginas web. Hay que usar el enlace directo al artefacto.

**9. Monitoreo.** Dos alarmas de CloudWatch que avisen antes de que se note
dentro del juego: `CPUCreditBalance` cerca de cero (la instancia burstable se
quedo sin credito) y un chequeo de que el puerto 25565 responda. La memoria no
aparece en CloudWatch sin el agente instalado.

**10. Actualizaciones de seguridad.** `unattended-upgrades` viene activo en
Ubuntu y aplica parches de seguridad, pero no reinicia solo. Revisar de vez en
cuando si hace falta reiniciar (`/var/run/reboot-required`); el servidor vuelve
solo gracias a systemd.

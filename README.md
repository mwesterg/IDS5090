# IDS5090 · Acceso remoto al laboratorio GPU

Contacto del administrador: [mwestermeyer@udec.cl](mailto:mwestermeyer@udec.cl).

IDS5090 permite a estudiantes trabajar en el PC del laboratorio mediante un
escritorio remoto XFCE y ejecutar sus tareas de entrenamiento en la GPU del equipo.
Cada estudiante dispone de una cuenta Linux, un directorio personal privado y un
perfil VPN individual.

El acceso previsto combina **WireGuard**, **OpenSSH** y **X2Go**, usando la VPN
WireGuard que ya existe en el servidor público. El laboratorio inicia su conexión
hacia ese servidor y no necesita redirección de puertos en su router.

**Dirección fija del laboratorio:** `10.8.0.100`. X2Go y SFTP usan
`10.8.0.100:22`. El perfil privado `IDS_5090.conf` ya está disponible localmente y
configurado con esa IPv4. El endpoint público de WireGuard es
`152.74.19.95:10275/UDP`. Hay que verificar la dirección activa, el handshake y el
acceso desde un estudiante antes de abrir el servicio al curso.

## Arquitectura

```text
 PC del estudiante                         PC del laboratorio GPU
 WireGuard + X2Go                          WireGuard + SSH + XFCE
         │                                          │
         │          Conexiones VPN salientes        │
         └─────────────────┬────────────────────────┘
                           │
                    Servidor público
                    WireGuard existente
                    152.74.19.95:10275/UDP

 Escritorio remoto: estudiante → VPN → 10.8.0.100:22
 Cómputo y almacenamiento de trabajo: PC del laboratorio
```

| Componente | Función |
| --- | --- |
| Servidor público | Registra peers individuales y enruta el tráfico autorizado entre estudiantes y laboratorio. |
| PC del laboratorio | Mantiene cuentas Linux, escritorios y procesos que utilizan la GPU; tiene un peer propio. |
| Equipo del estudiante | Tiene su propio peer WireGuard y muestra el escritorio remoto con X2Go Client. |

Cada equipo necesita claves y dirección VPN propias. El servidor público debe
permitir el forwarding entre peers y TCP 22 hacia el laboratorio, con tráfico de
retorno. Tener acceso a una VPN que solo ofrece salida a Internet no garantiza
que un estudiante pueda llegar al PC del laboratorio.

## Requisitos

- **VPN pública existente:** acceso de administración o colaboración de su
  administrador para registrar el laboratorio y los dispositivos de estudiantes,
  verificar `AllowedIPs`, rutas, forwarding y firewall.
- **Laboratorio:** Pop!_OS o Ubuntu 22.04/24.04, sudo/systemd y acceso UDP saliente
  al endpoint real de WireGuard.
- **Estudiantes:** WireGuard y X2Go Client. En macOS, seguir los requisitos de
  XQuartz indicados por X2Go.
- **Red:** reservar `10.8.0.100` para el laboratorio, comprobar el origen de los
  estudiantes en `10.8.0.0/24` y evitar solapamientos con LAN u otras VPN. Si el
  servidor aplica SNAT, revisar el CIDR que realmente ve SSH.

Los instaladores preparan acceso remoto. El driver NVIDIA, CUDA y el entorno de
entrenamiento se comprueban por separado en el laboratorio.

## Instalación

Clona el repositorio en el PC del laboratorio:

```bash
git clone https://github.com/mwesterg/IDS5090.git
cd IDS5090
```

Si ya trabajas en `~/IDS_remote`, utiliza ese directorio en lugar de clonar otra copia.

### 1. Preparar dependencias sin configuración VPN

```bash
sudo bash install_wireguard.sh --prepare
```

Este paso instala WireGuard y los paquetes SSH/X2Go/XFCE. No instala un perfil,
no cambia la red SSH de alumnos y no inicia WireGuard. La instalación de paquetes
puede iniciar servicios de la distribución. No se modifica el driver GPU.

### 2. Conectar con el perfil actual del laboratorio

El archivo privado `IDS_5090.conf` se mantiene fuera de Git. En el laboratorio:

```bash
cd ~/IDS_remote
chmod 600 IDS_5090.conf
sudo wg-quick up ./IDS_5090.conf
ip -4 address show dev IDS_5090
sudo wg show IDS_5090
```

Si el túnel ya está activo, no vuelvas a ejecutar `up`. Para recargar un cambio
al perfil, usa primero `sudo wg-quick down ./IDS_5090.conf` y luego `up`, desde
una terminal local. La interfaz debe mostrar `10.8.0.100/32` y un handshake
reciente. Los clientes usan `10.8.0.100` como host X2Go y SFTP.

El perfil actual incluye `::/0`: su tráfico IPv6 utiliza la VPN, además de las
rutas IPv4 de `10.8.0.0/24`. El validador del instalador rechaza rutas por defecto;
para este perfil revisado se utiliza `wg-quick` directamente. No borres rutas ni
claves para hacer pasar la validación. Mantén `PersistentKeepalive = 25`.

### 3. Preparar SSH/X2Go para los estudiantes

```bash
sudo bash -c 'source ./lib/remote_access.sh; configure_student_network 10.8.0.0/24'
```

Este paso configura SSH/X2Go para el origen VPN indicado. Conserva las políticas
personalizadas y respalda/migra únicamente snippets generados por el instalador.
Si hay SNAT, adapta el CIDR al origen real que ve el laboratorio. El firewall debe
permitir TCP 22 hacia `10.8.0.100` y el servidor público debe reenviar el tráfico
entre peers. Un handshake confirma conexión al servidor, no acceso de alumnos.

Consulta [WIREGUARD_DEPLOYMENT.md](WIREGUARD_DEPLOYMENT.md) para las rutas,
firewall, diagnóstico y la opción de instalación administrada con perfiles de
rutas explícitas. No actives dos interfaces a la vez con el mismo peer/perfil.

## Alta de estudiantes

El acceso requiere **una cuenta Linux en el laboratorio** y **un peer WireGuard
individual por dispositivo**, registrados por separado.

### Crear cuentas en el laboratorio

```bash
cp usuarios.example.txt usuarios.txt
# Editar usuarios.txt con los nombres reales del curso.
bash usr_mgr.sh --import usuarios.txt --dry-run
sudo bash usr_mgr.sh --import usuarios.txt
```

El archivo tiene un usuario por línea en formato `NombreApellido` (por ejemplo,
`JavierPina`), sin espacios y conservando las mayúsculas. Se admiten 3–31 caracteres:
letras, números, guiones o guiones bajos. Los usuarios existentes en minúsculas
siguen siendo válidos. Se permiten comentarios, líneas vacías y CRLF; se omiten
repetidos exactos.

Las cuentas se crean sin sudo y con HOME privado. La contraseña inicial es el
nombre de usuario en minúsculas y sin espacios, tanto al crear un alumno desde
el menú como al importar un TXT (ejemplo: `JavierPina` → `javierpina`). Es predecible;
el alumno puede cambiarla con `passwd`. Las cuentas existentes no se modifican. En X2Go y SFTP se escribe el usuario
con sus mayúsculas exactas (`JavierPina`); solo la contraseña inicial se convierte
a minúsculas (`javierpina`).
Las contraseñas se guardan en
archivos privados `credenciales-*.tsv` bajo `/root/credenciales-alumnos/`. El gestor
omite cuentas ya gestionadas sin resetearlas ni reactivarlas.

### Registrar peers VPN en el servidor existente

En la GUI WireGuard, el administrador crea/registra una clave pública y dirección
únicas para cada estudiante/dispositivo. `usr_mgr.sh` no emite perfiles WireGuard ni
modifica peers en el servidor público. Las plantillas
[lab.conf.example](wireguard/lab.conf.example) y
[student.conf.example](wireguard/student.conf.example) sirven para revisar la
estructura; requieren valores y claves reales antes de utilizarse.

Entrega por un canal privado solo el perfil y las credenciales Linux de cada
estudiante. No compartas el perfil del laboratorio ni el TSV completo del curso.
WireGuard usa la clave del perfil; X2Go solicita la contraseña Linux. Mantén
configuraciones reales fuera de Git; `.gitignore` excluye `.conf` y sus respaldos,
conservando las plantillas.

## Conexión de los estudiantes

**SSH es la forma recomendada de uso** para trabajar con código, ejecutar comandos
y entrenar modelos. El escritorio gráfico XFCE está siempre disponible mediante
X2Go cuando se necesite, con la misma cuenta y archivos. Ambos accesos requieren
que el servidor y la conexión WireGuard estén activos.

Primero importa/activa el perfil personal en WireGuard. Después, desde una terminal
del equipo del estudiante, usa el nombre asignado respetando sus mayúsculas:

```bash
ssh NombreApellido@10.8.0.100
# Ejemplo: ssh JavierPina@10.8.0.100
```

La contraseña inicial es el usuario en minúsculas (ejemplo: `javierpina`).
Para utilizar la GUI, crea una sesión X2Go con estos datos:

| Campo | Valor |
| --- | --- |
| Host | `10.8.0.100` |
| Puerto SSH | `22` |
| Usuario | `NombreApellido`, respetando mayúsculas |
| Tipo de sesión | `XFCE` (seleccionarlo explícitamente) |
| Autenticación | Contraseña Linux |

Mantén WireGuard conectado durante el uso de SSH, X2Go o SFTP. Todos se conectan
al laboratorio en `10.8.0.100:22`; la IP pública se usa para establecer WireGuard.
La [guía de clientes](CLIENT_GUIDE.txt) incluye SSH recomendado, GUI disponible,
transferencia de archivos, sesiones y diagnóstico.

## Uso de la GPU

Desde una terminal del escritorio remoto, comprueba el acceso con `nvidia-smi`.
Después, en el entorno Python utilizado para entrenar, ejecuta una prueba de
cálculo y gradientes:

```python
import torch

assert torch.cuda.is_available(), "CUDA no disponible en este entorno"
print(torch.__version__, torch.version.cuda, torch.cuda.get_device_name(0))
x = torch.randn(1024, 1024, device="cuda", requires_grad=True)
(x @ x).square().mean().backward()
torch.cuda.synchronize()
print("GPU: cálculo y gradientes correctos")
```

La GPU, la RAM y el disco son compartidos. El proyecto no asigna cuotas ni turnos;
el curso debe coordinar su uso. Las cuentas son usuarios Linux normales y conservan
el acceso habitual del equipo a la red y a archivos públicos del sistema.
Instala dependencias Python en entornos virtuales, sin conceder sudo a estudiantes.

## Administración

Listar alumnos del grupo gestionado (principal o suplementario), sin duplicados:

```bash
sudo bash usr_mgr.sh --list
```

Si el gestor estaba abierto durante una actualización, sal con `0` y vuelve a
ejecutarlo para cargar la versión actual.

En el laboratorio, agregar, listar, suspender, reactivar o eliminar cuentas:

```bash
sudo bash usr_mgr.sh
```

Retira también el peer WireGuard correspondiente en el servidor público, usando
la GUI y guardando el cambio de forma persistente. Suspender Linux no elimina
el peer; eliminar un peer no cierra los procesos de entrenamiento en el laboratorio.

Comprueba dos conexiones de alumnos desde fuera de la LAN, sus HOME/DISPLAY,
transferencias SFTP y cálculo GPU antes de abrir acceso a todo el curso.

## Documentación y archivos principales

| Archivo | Contenido |
| --- | --- |
| [WIREGUARD_DEPLOYMENT.md](WIREGUARD_DEPLOYMENT.md) | Despliegue WireGuard, rutas, firewall, validación y activación posterior. |
| [ADMINISTRATOR_GUIDE.txt](ADMINISTRATOR_GUIDE.txt) | Guía operativa del administrador, en inglés. |
| [CLIENT_GUIDE.txt](CLIENT_GUIDE.txt) | Instrucciones WireGuard/X2Go para estudiantes, en inglés. |
| [install_wireguard.sh](install_wireguard.sh) | Preparación e instalación del peer del laboratorio, sin autoarranque. |
| [wireguard_config.py](wireguard_config.py) | Validación local sin exponer claves. |
| [usr_mgr.sh](usr_mgr.sh) | Gestión de cuentas Linux e importación TXT. |
| [usuarios.example.txt](usuarios.example.txt) | Plantilla para la lista de estudiantes. |
| [lib/remote_access.sh](lib/remote_access.sh) | Funciones compartidas de SSH/X2Go y directorios de cuentas. |

El servidor público se administra desde su GUI WireGuard: crea un peer para el
laboratorio y uno por dispositivo de estudiante, y exporta sus perfiles por separado.
Los scripts se ejecutan en el laboratorio; no necesitan acceso SSH al servidor
público. Si la GUI no permite configurar el tráfico entre peers, su administrador
debe confirmar que el forwarding y las reglas de firewall ya lo permiten.

## Pruebas

Pruebas sin cuentas reales ni cambios de servicios, con perfiles temporales:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```

Fuentes oficiales: [WireGuard](https://www.wireguard.com/quickstart/),
[wg-quick](https://git.zx2c4.com/wireguard-tools/tree/src/man/wg-quick.8) e
[instalación de clientes](https://www.wireguard.com/install/).

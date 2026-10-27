# IDS5090 · Acceso remoto al laboratorio GPU

Contacto del administrador: [mwestermeyer@udec.cl](mailto:mwestermeyer@udec.cl).

IDS5090 permite a estudiantes trabajar en el PC del laboratorio mediante un
escritorio remoto XFCE y ejecutar sus tareas de entrenamiento en la GPU del equipo.
Cada estudiante dispone de una cuenta Linux, un directorio personal privado y un
perfil VPN individual.

El acceso previsto combina **WireGuard**, **OpenSSH** y **X2Go**, usando la VPN
WireGuard que ya existe en el servidor público. El laboratorio inicia su conexión
hacia ese servidor y no necesita redirección de puertos en su router.

**Estado:** falta recibir y revisar la configuración real de WireGuard. Los cambios
preparan la instalación y las guías; no se ha activado ni verificado un túnel, ni se
han asignado IP o claves reales.

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
                    Endpoint/puerto por confirmar

 Escritorio remoto: estudiante → VPN → IP WireGuard del laboratorio:22
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
- **Red:** confirmar IP del laboratorio, CIDR de origen que verá SSH y ausencia de
  solapamientos con LAN u otras VPN. Los valores de los ejemplos no son definitivos.

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

### 2. Validar e instalar cuando llegue el archivo real

Obtén un perfil exclusivo para el laboratorio y el CIDR de origen real de los
estudiantes. Sustituye los marcadores de estos comandos por los valores asignados:

```text
bash install_wireguard.sh --check-config /ruta/privada/lab.conf --student-network CIDR_REAL_ALUMNOS
sudo bash install_wireguard.sh --install /ruta/privada/lab.conf --student-network CIDR_REAL_ALUMNOS
```

La validación local no necesita root ni muestra claves. La instalación guarda el
perfil como `/etc/wireguard/ids-wg.conf`, root:root, modo 600; configura SSH/X2Go y
el acceso a las cuentas Linux. Se respalda y migra únicamente un snippet
SSH generado por el instalador, sin modificaciones manuales. La migración puede
afectar el acceso de alumnos por una VPN anterior: hazla con acceso local.

El instalador conserva configuraciones diferentes y rechaza interfaces ya activas.
Las rutas por defecto, hooks de shell y routing personalizado requieren revisión;
no se eliminan automáticamente del archivo. Un perfil con DNS necesita integración
`resolvconf`. Revisa esos requisitos antes de ejecutar `--install`.

### 3. Activar después de revisar rutas y firewalls

```bash
sudo systemctl enable --now wg-quick@ids-wg
sudo bash install_wireguard.sh --status
```

`--install` no arranca ni habilita la VPN; la activación es un paso separado.
`--status` comprueba el servicio, la interfaz y la antigüedad de los handshakes.
Un handshake reciente demuestra conectividad al servidor público, pero todavía
hay que probar el acceso estudiante → laboratorio por TCP 22.

Consulta [WIREGUARD_DEPLOYMENT.md](WIREGUARD_DEPLOYMENT.md) para los detalles de
la VPN existente, firewall, migración, DNS, rutas y recuperación. Los scripts no
reconfiguran el servidor público ni detienen las VPN anteriores.

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

El archivo tiene un usuario por línea, de 3 a 31 caracteres: empieza con letra
minúscula y continúa con minúsculas, números, guiones o guiones bajos. Se permiten
comentarios, líneas vacías y CRLF; se omiten repetidos.

Las cuentas se crean sin sudo y con HOME privado. Las contraseñas se guardan en
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

1. Importar/activar el perfil personal en WireGuard.
2. Crear una sesión en X2Go Client:

   | Campo | Valor |
   | --- | --- |
   | Host | IP WireGuard real del laboratorio, por confirmar |
   | Puerto SSH | `22` |
   | Usuario | Cuenta Linux asignada |
   | Tipo de sesión | `XFCE` |
   | Autenticación | Contraseña Linux |

3. Verificar la huella SSH entregada por el administrador.
4. Mantener WireGuard conectado durante la sesión.

El destino X2Go y SFTP es el laboratorio, no la IP pública del servidor VPN.
La [guía de clientes](CLIENT_GUIDE.txt) incluye instalación, transferencia de
archivos, suspensión de sesiones y diagnóstico.

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

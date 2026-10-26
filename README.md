# Servidor docente OpenVPN + X2Go

Estas herramientas dan a cada alumno una cuenta Linux sin sudo, HOME privado,
certificado VPN individual y escritorio XFCE por SSH/X2Go. No instalan ni cambian
NVIDIA/CUDA ni el escritorio físico. Los originales están en `backups/`.

Guías en texto plano (en inglés): [administrador](ADMINISTRATOR_GUIDE.txt) y
[alumnos/clientes](CLIENT_GUIDE.txt). La guía de clientes se puede distribuir
al curso después de proporcionar a cada alumno sus datos de acceso privados.

## Opción actual: servidor público OpenVPN + PC del laboratorio como cliente

La red institucional bloquea Tailscale. El despliegue actual usa un servidor
público Ubuntu/Debian como hub OpenVPN; el PC del laboratorio conecta hacia él
sin puertos entrantes. Los alumnos conectan al mismo hub y usan X2Go hacia
`10.77.0.2:22`. Las cuentas Linux y la GPU permanecen en el PC del laboratorio.

Consulta [HUB_DEPLOYMENT.md](HUB_DEPLOYMENT.md) para instalación, firewall,
migración de Tailscale, certificados y mantenimiento. Comandos principales:

```bash
# En el servidor público Ubuntu 152.74.19.95:
sudo bash install_hub.sh init 152.74.19.95 443 tcp
sudo bash install_hub.sh add-student alumno01

# Copiar labpc.ovpn de forma privada al PC del laboratorio y ejecutar allí:
sudo bash install_lab.sh /ruta/privada/labpc.ovpn
sudo bash usr_mgr.sh --linux-only --import usuarios.txt
```

TCP 443 es configurable y debe estar libre en el hub. Que el puerto esté abierto
no garantiza que la institución permita OpenVPN; verifica la conexión saliente.
Los instaladores anteriores se conservan para despliegues existentes.

## Alternativa anterior: Tailscale (bloqueada en esta red)

Tailscale puede conectar mediante NAT traversal o relés con conexiones salientes.
No necesitas terminar la instalación OpenVPN ni disponer de IP pública. Utilízalo
si está permitido en la institución; una red que bloquee Tailscale puede impedirlo.
Los relés pueden reducir velocidad, pero el entrenamiento se ejecuta en este PC.
La instalación está preparada; no está activada desde la sesión restringida de Codex.

Desde una terminal normal/local del PC:

```bash
cd ~/IDS_remote
sudo bash install_tailscale.sh
```

Abre el enlace de autenticación que muestre e inicia sesión con una cuenta
apropiada para el laboratorio. El script instala Tailscale desde su repositorio
firmado oficial y configura SSH/X2Go/XFCE. No cambia OpenVPN, NVIDIA/CUDA ni UFW.
Se usa OpenSSH normal, con contraseña Linux individual; Tailscale SSH se desactiva.
El script imprime la IP Tailscale del PC y selecciona cuentas sin certificados
como modo predeterminado en `/etc/ids-remote-access.mode`.

Prepara la lista REAL antes de crear cuentas (el archivo de ejemplo no es una
lista del curso):

```bash
cp usuarios.example.txt usuarios.txt
# Editar usuarios.txt.
bash usr_mgr.sh --linux-only --import usuarios.txt --dry-run
sudo bash usr_mgr.sh --linux-only --import usuarios.txt
```

Las contraseñas individuales quedan en `/root/credenciales-alumnos/credenciales-*.tsv`.
No se emiten perfiles `.ovpn` ni se requiere PKI en este modo. Distribuye únicamente
la contraseña propia de cada alumno. No distribuyas el TSV completo.

En la consola Tailscale comparte **solo este PC** con cada alumno, usando su propia
cuenta. Cada alumno debe instalar Tailscale y aceptar el acceso al equipo.
No se envían invitaciones automáticamente. Revisa que el plan/contrato permita
el uso previsto para el curso.

`tailscale-policy.example.json` es una plantilla para limitar usuarios compartidos
a TCP 22: sustituye `100.100.100.100` por la IP real del servidor. Adapta la política
manualmente conservando los accesos administrativos necesarios. Las reglas son
aditivas: una regla previa más amplia seguirá permitiendo otros puertos. No
reemplaces a ciegas una política existente ni supongas que agregar esta regla
elimina permisos anteriores.

En X2Go Client: IP Tailscale del PC (100.x.y.z), puerto SSH 22, sesión XFCE y
usuario/contraseña Linux individual. Primero prueba desde otro dispositivo fuera
de la LAN, después dos alumnos simultáneos y finalmente el cálculo GPU de abajo.
Si hay otros snippets SSH o reglas de firewall, revisa el comportamiento efectivo
antes de abrir acceso al curso. No necesitas publicar SSH en Internet.

La suspensión/eliminación Linux y el permiso Tailscale son independientes: retira
también el acceso del alumno en la consola cuando corresponda. Si una cuenta tiene
certificado OpenVPN existente, el modo Linux impide eliminarla hasta revocarlo
con `sudo bash usr_mgr.sh --openvpn`.

Para otra VPN/red privada, `sudo bash install_server.sh --student-network CIDR_REAL`
prepara SSH/X2Go y el modo Linux. No configura rutas ni una VPN externa. No se
sobrescribe una configuración con otro CIDR sin revisarla manualmente.

Fuentes: [Linux](https://tailscale.com/docs/install/linux),
[paquetes oficiales](https://dl.tailscale.com/stable/),
[conexiones por relé](https://tailscale.com/docs/reference/connection-types),
[compartir un equipo y limitar permisos](https://tailscale.com/docs/features/sharing).

## Estado observado el 26 de octubre de 2026

- Pop!_OS 22.04; paquetes OpenVPN 2.5, Easy-RSA, OpenSSH, X2Go y XFCE instalados.
- OpenVPN está habilitado en systemd, pero eso no demuestra que funcione.
- `/etc/openvpn/server/server.conf` existe. En ese directorio faltan `ca.crt`,
  `servidor.crt`, `servidor.key`, `crl.pem` y `tls-crypt.key` referenciados por él.
- La sesión de Codex no tiene acceso a systemd, interfaces de red ni dispositivos
  GPU y no puede usar sudo (`no new privileges`). No se cambiaron servicios,
  firewall, cuentas reales ni configuración del sistema.
- `nvidia-smi` falla en esta sesión; el módulo visible informa 535.104.05.
  Esto NO valida el estado del host ni que la RTX 5090 pueda entrenar.
- No se puede leer `/root` desde esta sesión: hay que comprobar allí la PKI.

## Alternativa OpenVPN: requiere entrada UDP 1194

```bash
cd ~/IDS_remote
sudo bash install_server.sh --check
```

Si solo hay `server.conf`, sin PKI en `/root/easy-rsa/pki` y sin ninguno de los
cinco archivos criptográficos anteriores, ejecutar:

```bash
sudo bash install_server.sh --complete-incomplete
```

El instalador pide el DNS/IP público y la contraseña de la CA, instala dependencias,
crea la PKI, respalda el `server.conf` anterior y configura los servicios. No
permite esta opción si ya existen claves/certificados o una PKI. Guarda la
contraseña de la CA: se necesita para emitir y revocar certificados. Acepta la
configuración UFW si corresponde a tu red; conserva acceso SSH administrativo
indicando la IP/CIDR de administración cuando se solicite.

Si ya tienes todos los certificados y las claves desplegados:

```bash
sudo bash install_server.sh --repair-existing
```

La reparación comprueba rutas, certificado/clave y CRL antes de configurar SSH y
arrancar servicios. Conserva `server.conf`, PKI, claves y firewall. Si existe el
snippet SSH `00-alumnos-x2go.conf`, se conserva: revisa sus reglas manualmente.
Si la PKI existe pero faltan archivos desplegados, recupera esos archivos desde
la PKI/copias de seguridad; no borres la CA ni generes otra para intentar reparar.
Una clave `tls-crypt` perdida requiere actualizar los perfiles de los clientes.

Para una instalación completamente nueva, sin `server.conf` ni PKI:

```bash
sudo bash install_server.sh
```

El DNS/IP público debe alcanzar este PC por UDP 1194. En el router se necesita
una reserva DHCP/IP fija para el PC y redirección UDP 1194. CGNAT o restricciones
de la universidad pueden impedir la entrada. No se cambia el router con estos
scripts. La red VPN 10.8.0.0/24 no debe solaparse con redes usadas por los alumnos.
Los estudiantes acceden al servidor por 10.8.0.1; no se redirige su Internet.

## Importar alumnos desde TXT

Copia `usuarios.example.txt` a `usuarios.txt` y sustituye los ejemplos por la lista
real. Formato: un nombre por línea, 3 a 31 caracteres, empezando con letra
minúscula y continuando con minúsculas, números, `_` o `-`. `servidor` está
reservado. Se admiten CRLF, espacios en los extremos y comentarios `#`; los
nombres repetidos se procesan una sola vez. No se admiten columnas de contraseñas.

```bash
bash usr_mgr.sh --import usuarios.txt --dry-run
sudo bash usr_mgr.sh --import usuarios.txt
```

También está disponible la opción **6** del menú `sudo bash usr_mgr.sh`.

La vista previa valida solo el TXT. En modo OpenVPN, la importación real valida conflictos antes
de crear cuentas y omite alumnos ya gestionados con perfil, clave y certificado
válido/no revocado. No adopta cuentas Linux existentes ni reutiliza identificadores
revocados. Un bloqueo impide ejecutar dos gestores simultáneamente.

Cada cuenta recibe una contraseña aleatoria, usada también para cifrar su clave
VPN. Se registra en un archivo `credenciales-*.tsv` privado (modo 600) dentro de
`/root/perfiles-openvpn/`. La CA puede pedir su contraseña por cada alumno. No
se imprimen contraseñas. Cada TSV contiene una fila inicial de recuperación y,
cuando el alumno termina correctamente, otra fila con estado `creado`.

Distribuye a cada alumno únicamente su contraseña y `/root/perfiles-openvpn/USUARIO.ovpn`
por un canal privado. No distribuyas el TSV completo, la CA privada ni perfiles de
otros alumnos. Guarda o elimina el TSV según la política de credenciales del curso.

Si falla un certificado o perfil, la importación se detiene y bloquea la cuenta
afectada. Las cuentas anteriores quedan creadas. Conserva el TSV y revisa cuenta,
PKI y perfil antes de reintentar; la siguiente ejecución detecta estados parciales.
La suspensión del menú bloquea Linux, pero no revoca el certificado VPN. La
eliminación revoca VPN, reinicia OpenVPN y archiva HOME.

## Conexión de un alumno y prueba de entrenamiento

1. Importar el `.ovpn` en un cliente OpenVPN y conectar con la contraseña de la clave.
2. En X2Go Client: host `10.8.0.1`, puerto SSH `22`, usuario asignado, sesión `XFCE`.
3. Entrar con la contraseña Linux asignada y verificar que HOME y usuario son propios.
4. Ejecutar `nvidia-smi` desde una terminal de esa sesión.
5. En el entorno Python de entrenamiento ejecutar:

```python
import torch
assert torch.cuda.is_available()
print(torch.__version__, torch.version.cuda, torch.cuda.get_device_name(0))
x = torch.randn(1024, 1024, device="cuda", requires_grad=True)
(x @ x).square().mean().backward()
torch.cuda.synchronize()
print("GPU: cálculo y gradientes correctos")
```

Si `nvidia-smi` falla también en una terminal normal del host, resolver el driver
antes de ofrecer entrenamiento. Blackwell requiere módulos NVIDIA abiertos y un
framework compatible con la RTX 5090; no se debe dar por válido el driver 535
observado aquí. Selecciona paquetes compatibles con Pop!_OS y verifica otra vez
tras cualquier reinicio. Los entornos Python se instalan por alumno con venv.

Esta configuración no asigna cuotas, turnos, GPU dedicada, límites de RAM o disco.
Las cuentas comparten la misma GPU: coordina entrenamientos para evitar agotar
VRAM. Son cuentas Linux normales, no contenedores; pueden leer archivos públicos
del sistema. No concedas sudo para instalar bibliotecas de Python.

## Comprobaciones y mantenimiento

Para Tailscale:

```bash
sudo systemctl status tailscaled ssh x2goserver --no-pager
tailscale status
tailscale ip -4
sudo sshd -T -C user=alumno01,addr=100.64.0.2,host=cliente
sudo ufw status numbered
```

Solo para la alternativa OpenVPN:

```bash
sudo bash install_server.sh --check
sudo systemctl status openvpn-server@server ssh x2goserver --no-pager
sudo journalctl -u openvpn-server@server -n 80 --no-pager
sudo sshd -T -C user=alumno01,addr=10.8.0.2,host=cliente
```

Para OpenVPN, prueba una conexión real desde fuera de la red local; escuchar UDP 1194 no
confirma que el router lo reenvíe. Prueba dos alumnos simultáneos con distintos
HOME/DISPLAY y el cálculo CUDA anterior. Evita reglas antiguas que permitan SSH
desde Internet si la política del laboratorio exige acceso solo por VPN.

La CRL creada por el instalador dura 180 días; las renovaciones manuales o del
gestor pueden tener otro plazo. Revisa `nextUpdate` y renueva ANTES de caducar.
La CA está cifrada, por lo que no se configura una renovación automática sin
intervención. Para renovar con 180 días:

```bash
sudo bash -c 'cd /root/easy-rsa && EASYRSA_CRL_DAYS=180 ./easyrsa gen-crl && install -m 644 pki/crl.pem /etc/openvpn/server/crl.pem'
sudo openssl crl -in /etc/openvpn/server/crl.pem -noout -nextupdate
```

OpenVPN relee la CRL al autenticar clientes; el archivo y los directorios padres
deben permitir lectura/tránsito al usuario `nobody`. Respaldar la CA cifrada fuera
del servidor. Un certificado de alumno revocado no se reutiliza.

Pruebas sin root (cuentas simuladas; PKI y claves reales temporales):

```bash
python3 -m unittest discover -s tests -v
```

Referencias: [OpenVPN 2.5](https://openvpn.net/community-docs/community-articles/openvpn-2-5-manual/),
[revocación y permisos de CRL](https://openvpn.net/community-docs/revoking-certificates/),
[X2Go Server](https://wiki.x2go.org/doku.php/doc:installation:x2goserver),
[módulos NVIDIA para Blackwell](https://developer.nvidia.com/blog/nvidia-transitions-fully-towards-open-source-gpu-kernel-modules/).

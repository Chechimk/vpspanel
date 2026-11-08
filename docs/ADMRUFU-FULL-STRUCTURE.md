# ADMRufu2.0: observed structure and behaviour

This is a record of the **running** ADMRufu2.0 panel, made to guide VPSPanel's
independent re-implementation. It replaces the earlier, string-table-based
[ADMRUFU-MENU-MAP.md](ADMRUFU-MENU-MAP.md) wherever the two disagree.

No ADMRufu code, binary, translation catalog, help text or artwork is copied
into VPSPanel. Menu labels are quoted below in the original Spanish (with an
English translation) only to identify each screen.

## Test environment

| Item | Value |
|---|---|
| Date | 2026-11-08 |
| Installer | `https://gitlab.com/rufu99/admrufu2.0/-/raw/main/install.sh` (SHA-256 `cfbd18cd…886386`), which downloads the compiled `install` (SHA-256 `8f6a525d…b0d74b`) and the license program `install-LIC_2.0` |
| System | Disposable Docker container, Ubuntu 22.04.5, systemd as PID 1, privileged, on a Windows 11 host. Snapshots were taken before installing, after licensing and after exploring. |
| License | Entered by the owner directly in the installer's terminal. The key is not recorded anywhere in this repository. |
| Panel language | Spanish (default). The English option exists but was not used for the walkthrough. |
| Xray version installed by the panel | Xray 25.3.6; Hysteria v2.2.2 |

The server's public IP is replaced by `<server-ip>` everywhere below.

### Verification marks

| Mark | Meaning |
|---|---|
| 🔬 | **Observed and tested**: the screen was used and its effect on the system was inspected (files, services, firewall, real traffic). |
| ✅ | **Observed**: the screen and its prompts were seen in the running panel; the action was not completed or its effect was not inspected. |
| ⚠️ | **Observed broken**: the option ran but did not work in this environment (details given). |
| 📦 | **Container limit**: the result depends on the real kernel or public network and may differ on a VPS. |
| ❔ | **Not observed**: not opened during this session; anything said about it is an inference. |

## Installer behaviour (observed)

The bootstrap `install.sh` (Bash, readable):

1. enables systemd lingering for root and creates `/run/user/0`;
2. installs `gnupg wget software-properties-common lsb-release`;
3. **on Ubuntu, adds the `ppa:ubuntu-toolchain-r/test` repository and
   upgrades `libstdc++6` from it** (to a GCC 16 test build on 22.04);
4. installs `libcurl4-openssl-dev`, downloads the compiled `install` and runs it.

The compiled `install` (strings and observed actions):

- downloads and runs the license program, which shows a menu
  (`[1] INSTALAR LICENCIA`, `[2] DESINSTALAR SCRIPT`, `[0] CANCELAR`) and asks
  for the key. Its strings include a "key already used" message, so keys
  appear to be single-use;
- can replace `/etc/apt/sources.list` and delete `/etc/apt/sources.list.d/*`,
  and runs `apt update; apt upgrade`;
- clones the panel to `/etc/ADMRufu2.0`, links `/etc/ADMRufu2.0/etc` to
  `/root/ADMRufu` (all runtime data lives there) and writes `/etc/ADMRufuLIC`;
- adds `source /etc/ADMRufu2.0/bashrc` to `/etc/bash.bashrc`. That file prints
  a login banner and defines the aliases `menu`, `monitor`, `api`, `tgbot`,
  `wsbot`, `update-adm`, `remove-adm`;
- creates three **user-level** systemd units for root: `update-adm.service`
  (`git pull` of the panel at every login, so the panel auto-updates),
  `contador.service` (account counter) and `monitor-cpu.service`;
- **reboots the server** at the end ("REINICIANDO VPS EN 10 SEGUNDOS").

`/etc/ssh/sshd_config` is not changed by the installer itself. It is changed
the first time *Protocol configuration > SSH settings* is opened (see below).

## Screen layout and colours (observed)

Every screen is 60 columns wide:

```
════════════════════════════════════════════════════════════   red, double line
                    SCREEN TITLE                               bold white, centred
════════════════════════════════════════════════════════════
  [1]> ITEM LABEL                                              [n] green, > red, label bold white
  [2]> ITEM LABEL
------------------------------------------------------------   red dashes: group separator
 [10]> ITEM LABEL                                              two-digit numbers shift left one column
════════════════════════════════════════════════════════════
  [0] Volver               [11] EXTRA ACTION                   footer: Back plus 1-2 extra actions
════════════════════════════════════════════════════════════
 Ingresa una Opcion:                                           prompt ("Enter an option:")
```

- Labels are upper case. Status is appended in brackets: `[ON]` green, `[OFF]`
  red.
- A finished action prints status lines such as
  `           systemctl restart dropbear.........OK` (a spinner turns into OK or
  Failed), then `>> Presione enter para continuar <<` ("press Enter to
  continue").
- Confirmation footers use `[0] VOLVER   [1] REINTENTAR   [2] GUARDAR` (Back,
  Retry, Save) or `Enter guardar` (Enter saves).
- Port prompts accept several ports separated by spaces and check each one:
  `Port 22........EN USO!` (in use) or `Port 143.......DISPONIBLE!` (available).
  Ports in use are dropped silently when saving.
- "Which port should traffic be forwarded to?" screens list every listening
  TCP service as `[n] > name......port`, plus `INGRESA MANUALMENTE` (enter
  manually).
- An invalid main-menu choice simply redraws the screen.

### Main-menu header (dashboard)

```
════════════════════════════════════════════════════════════
                          @Rufu99                              bold yellow (reseller name)
╔══════════════════════════════════════════════════════════╗   red
  S.O:    Ubuntu 22.04.5 LTS             Fecha:  08-11-2026    labels green, values white
  IP:     <server-ip>                    Hora:   15:07:56
╠═════════════════Disc═════════════════╦════════CPU════════╣   optional (Script settings 3)
  Total:  1006.85GB  Dispo:  947.25GB    Cores:  8
  En Uso: 8.38GB     Libre:  998.47GB    En Uso: 1.38%
╠═══════════════════════════ram════════╩═══════════════════╣   optional (Script settings 4)
  Total:  7.67GB     En Uso: 1.24GB      Libre:  317.44MB
  Buffer: 773.86MB   Cache:  5.36GB
╠═══════════════════════════swap═══════════════════════════╣   optional (Script settings 5)
  Total:  2.00GB     Libre:  2.00GB      En Uso: 4.02MB
╚══════════════════════════════════════════════════════════╝
   ACTIVA: 2    EXPIRADA: 0    BLOQUEADA: 1    TOTAL: 3       green / red / cyan / yellow
════════════════════════════════════════════════════════════
```

The bottom bar of the main menu uses background colours:
`[0]` white on red, the "exit script" item white on grey, "reboot" white on blue.

## 1. Main menu 🔬

The list is **dynamic**: account menus for V2Ray/Xray and WireGuard appear only
once those protocols are installed, and the numbers below them shift.

| # (fresh) | # (all installed) | Label | Translation | Behaviour |
|---|---|---|---|---|
| 1 | 1 | ADMINISTRAR CUENTAS (SSH/DROPBEAR) | Manage accounts (SSH/Dropbear) | §2 |
| – | 2 | ADMINISTRAR CUENTAS (V2RAY/XRAY) | Manage accounts (V2Ray/Xray) | §3.15b, only after Xray is installed |
| – | 3 | ADMINISTRAR CUENTAS (WIREGUARD) | Manage accounts (WireGuard) | §3.17b, only after WireGuard is installed |
| 2 | 4 | CONFIGURACION DE PROTOCOLOS | Protocol configuration | §3 |
| 3 | 5 | HERRAMIENTAS EXTRAS | Extra tools | §4 |
| 4 | 6 | CONFIGURA API Y BOTS | API and bots | §5 |
| 5 | 7 | CONFIGURACION DEL SCRIPT | Script settings | §6 |
| 6 | 8 | IDIOMA / LANGUAGE | Language | Spanish / English. Changing it exits the panel to the shell. |
| 7 | 9 | [!] DESINSTALAR PANEL | Uninstall panel | Asks `Desea continuar? [S/N]` (continue? Y/N) |
| 0 | 0 | SALIR DEL VPS | Leave the VPS | **Ends the whole SSH session** (observed: the terminal closed) |
| 8 | 10 | SALIR DEL SCRIPT | Exit the script | Returns to the shell |
| 9 | 11 | REINICIAR VPS | Reboot the VPS | Not run in this test |

Groups are separated by dashed lines: accounts | protocols, extras | API |
settings, language | uninstall.

## 2. Manage accounts (SSH/Dropbear) 🔬

Title: `ADMINISTRACION DE USUARIOS SSH`. With "show temporary users" enabled
(§2.14) a *Create temporary user* item is inserted at position 2 and the rest
shift down by one.

| # | Label | Translation | Observed behaviour |
|---|---|---|---|
| 1 | NUEVO USUARIO | New user | 🔬 Shows the user table, then asks NOMBRE (name), CLAVE (password), EXPIRA EN (days), CONECCIONES (connection limit). Footer `[0] Volver [1] Reintentar Enter guardar`. Validation: the name may be 1+ characters ("0" and "ab" were accepted); the password must be non-empty (3 characters accepted); days and limit must be numbers, 0 accepted. Result screen shows server IP, name, password, expiry as "N DIAS (date)", connections. |
| 2* | CREAR USUARIO TEMPORAL | Create temporary user | 🔬 NOMBRE, MINUTOS (minutes), CONECCIONES. Starts a background `/tmp/<user>` script that sleeps for the given minutes and then deletes the user (observed: deleted after 2 minutes). |
| 2 | REMOVER USUARIO | Remove user | ✅ Pick a user by number from the table. |
| 3 | RENOVAR USUARIO | Renew user | 🔬 Pick a user, enter days. The expiry is **set to today + days** (it does not extend the current date). |
| 4 | EDITAR USUARIO | Edit user | 🔬 Pick a user, then CLAVE (new password) and CONECCIONES (new limit) in one step. |
| 5 | BLOQUEAR/DESBLOQUEAR USUARIO | Lock/unlock user | 🔬 Toggles the lock (`passwd -l`, shadow hash prefixed with `!`) and kills the user's processes. Table status column shows LOK/ULK. |
| 6 | CONFIGURAR CONTRASEÑA GENERAL | General password | 🔬 Submenu: `[1] STATUS [ON/OFF]`, `[2] PASS`. When ON, *New user* and *Create temporary user* skip the password prompt and use the general password. |
| 7 | DETALLES DE TODOS USUARIOS | Details of all users | 🔬 Table `N° Usuario Fecha Dia Lim Sta` with the password on a second line. |
| 8 | MONITOR DE USUARIOS CONECTADOS | Online users monitor | 🔬 Full-screen table (in English) `NAME / REAL-TIME ONLINE USERS / ONLINE / LIMIT`, paged with ←/→ or g/h, Ctrl+C to leave. Counted 1 session for a user with one SSH tunnel. |
| 9 | LIMITADOR-DE-CUENTAS | Account limiter | §2.9 |
| 10 | ELIMINAR USUARIOS VENCIDOS | Delete expired users | ✅ |
| 11 | ELIMINAR TODOS LOS USUARIOS | Delete all users | ✅ |
| 12 | ADMINISTRACION COPIAS DE USUARIOS | User backups | §2.12 |
| 13 | DESACTIVAR CONTRASEÑA ALFANUMERICA | Disable alphanumeric password | 🔬 Installs `libpam-cracklib` and leaves `/etc/pam.d/common-password` without a strength module (only `pam_unix.so obscure sha512`), so simple passwords are accepted. |
| 14 | CONFIGURACION DEL ADMINISTRADOR DE CUENTAS | Account manager settings | §2.14 |
| 0 | Volver | Back | |
| 15 | CAMBIAR A MODO SSH/HWID/TOKE[N] | Switch to SSH/HWID/TOKEN mode | §2.15 |

**Storage (🔬).** Accounts are ordinary Linux users with shell `/bin/false`,
their own group and a non-existent home `/home/<name>`. The connection limit and
the **plain-text password** are stored in the GECOS field of the
world-readable `/etc/passwd` (`ab:x:1000:1000:20,<password>:/home/ab:/bin/false`).
Expiry uses the account expiry date (`chage -E`).

### 2.9 Account limiter 🔬 ⚠️

```
[1] LIMITADOR DE CUENTAS EXPIRADAS [OFF]     expired-accounts limiter
[2] VER LOG DE CUENTAS EXPIRADAS             view expired log
[3] LIMITADOR DE CONIECCIONES MULTIPLES [OFF] multi-login limiter
[4] VER LOG DE CONECCIONES MULTIPLES         view multi-login log
[5] LIMPIAR LOG DE EXPIRADO <size>           clear expired log (appears when ON)
[0] Volver   [5] Notas
```

Turning the multi-login limiter on prints `instalado monitor....OK` and copies a
`monitor` binary to `/root/ADMRufu/userSSH/`. **In this environment it never
enforced anything**: every run logged
`monitor: error while loading shared libraries: libip.so` (the library exists
only in `/etc/ADMRufu2.0/lib`, which is not on the loader path). A user with
limit 1 kept two SSH sessions for more than an hour. This looks like a real
defect, not a container limitation.

### 2.12 User backups 🔬

```
[1] AUTO-BACKS: [OFF]                   automatic backups toggle
[2] CREAR UNA NUEVA COPIA DE USUARIOS   create a backup
[3] RESTAURAR COPIA DE USUARIOS         restore (pick from a list)
[4] ELIMINAR COPIA DE USUARIOS          delete a backup
```

A backup is `/root/ADMRufu/userSSH/backups_users_DD-MM-YYYY_HH:MM:SS.admrufu`,
a JSON file:

```json
{ "ssh": { "<user>": { "conecciones": 20, "expira": "2026-11-13", "pass": "<plain-text password>" } } }
```

### 2.14 Account manager settings 🔬

```
            MOSTRAR LISTA DE USUARIO           (show the user list in…)
[1] CREAR USUARIOS [ON]                         …New user
[2] REMOVER USUARIOS [ON]                       …Remove
[3] RENOVAR USUARIOS [ON]                       …Renew
[4] EDITAR USUARIOS [ON]                        …Edit
[5] BLOQUEAR/DESBLOQUEAR USUARIOS [ON]          …Lock/unlock
[6] MODO DE SELECCION POR NOMBRE/ID/TOKEN/HWID [OFF]   select users by name instead of number
[7] MOSTRAR OPCION USUARIOS TEMPORALES [OFF]    show the temporary-user option
[8] VISUALIZAR FECHA EN ZONA HORA (DEFAULT UTC) [OFF]  show dates in the server time zone
[9] FIX HWID HTTPCUSTOM V7.9.17 (743) [OFF]     compatibility fix for one HTTP Custom version (❔ effect)
[0] Volver   [10] Guardar y salir (save and exit)
```

Settings are stored in `/root/ADMRufu/userSSH/setting` as `key=0|1` lines
(`sshMode`, `hwidMode`, `tokenMode`, `addUserL`, `delUserL`, `renewUserL`,
`editUserL`, `lockUserL`, `selectMode`, `htcustom`, `backups`, `enableTMP`,
`timeZONE`, `passGenMode`, `passGenModeSsh`, `passwordSSH`).

### 2.15 Account modes 🔬

Choosing *HWID* or *TOKEN* switches the whole account menu to that mode (the
title becomes `ADMINISTRACION DE USUARIOS HWID`, and *Edit user* and *General
password* disappear). In HWID mode *New user* asks NOMBRE ID (display name),
HWID and days. The Linux user name **is the HWID**, and the GECOS field holds
`hwid,<display name>` (🔬). How HTTP Custom then authenticates (which password
it sends) was not observed (❔).

## 3. Protocol configuration 🔬

Title `ADMINISTRADOR DE PROTOCOLOS`. A summary of open ports by service is
printed above the list in two columns (`DROPBEAR: 109 143   PYTHON3: 8080 8081`,
`SSH: 22 2222   STUNNEL: 443`, `SLOWDNS: 5300`, `UDP-CUSTOM: 36712`,
`UDP-HYSTERIA: 36800`, `OPENVPN-TCP: 1194`, `BADVPN: 7300`, `SQUID: 3128 8000`).
The protocol list is in two columns with a coloured status:

```
[1] AJUSTES SSH       [ON]   [11] OPENVPN           [OFF]
[2] DROPBEAR          [OFF]  [12] CHECKUSER ONLINE  [OFF]
[3] SOCKS PYTHON      [OFF]  [13] ATKEN and HASH    [OFF]
[4] STUNNEL (SSL)     [OFF]  [14] FILEBROWSER       [OFF]
[5] SLOWDNS           [OFF]  [15] V2RAY/XRAY        [OFF]
[6] WS-EPRO           [OFF]  [16] SSHGO             [OFF]
[7] UDP-CUSTOM        [OFF]  [17] WIREGUARD         [OFF]
[8] UDP-HYSTERIA      [OFF]  [18] HCR CUSTOM        [OFF]
[9] BADVPN-UDPGW      [OFF]  [19] BHTTP TUNNEL      [OFF]
[10] SQUID            [OFF]
[0] Volver
```

Before a protocol is installed its screen shows only
`[0] Volver   [1] INSTALAR <NAME>` (install).

### 3.1 SSH settings 🔬

Opening this screen the first time applies "initial settings" without asking:
it backs up `sshd_config` to `sshd_config.back`, comments out the `Port`,
`TCPKeepAlive` and `ClientAlive*` lines and adds
`sshd_config.d/98-KeepAlive.conf` (`ClientAliveInterval 5`,
`ClientAliveCountMax 2`, `TCPKeepAlive yes`) and `sshd_config.d/99-ports.conf`.

```
      PUERTOS: 22
[1] MODIFICAR PUERTO SSH                 change SSH ports (several, space-separated)
[2] CONFIGURAR BANNER SSH                banner (§3.1a)
[3] CONFIGURAR CLAVE Y ACCESO ROOT       root password and root login
[4] INICIAR/DETENER SERVIDOR SSH [ON]    start/stop
[5] REINICIAR SERVIDOR SSH               restart
[0] VOLVER   [6] DESINSTALAR OPENSSH-SERVER
```

Changing ports to `22 2222` wrote both to `99-ports.conf` and restarted
`ssh`/`sshd` (🔬, both ports listened).

**3.1a Banner (🔬).**
`[1] BANNER DE CONECCION [OFF]` (pre-login banner: `sshd_config.d/banner.conf`
with `Banner /root/ADMRufu/banner/banner`),
`[2] BANNER DE AUTENTICACION + CHECKUSER [OFF]` (post-login banner),
`[3] CREAR, EDITAR BANNER (nano)`, `[4] AYUDA` (help). The two banner types
are mutually exclusive. The post-login banner works through PAM:
`/etc/pam.d/checkuser` (`pam_exec` runs a program that writes a per-user copy
of the banner, then `pam_echo` prints it), included from `/etc/pam.d/sshd`. The
help explains that the keywords `USER`, `EXP` and `DAYS` in the banner are
replaced with the account's name, expiry date and days left (`never` when
there is no expiry).

**3.1b Root access (✅).** `[1] ACTIVAR ACCESO ROOT [OFF]`, `[2] ASIGNAR CLAVE ROOT`.

### 3.2 Dropbear 🔬

Install screen: a note that on Debian the install can freeze (then use option 2),
`[1] INSTALAR DROPBEAR`, `[2] INSTALAR DROPBEAR FIX`,
`[3] INSTALAR DROPBEAR MOD By @Rufu99` (❔ 2 and 3 not run).
Option 1 asks for several ports (`EJ: 80 90 109 110 143 443`), checks each, and
installs the distribution package. Ports `143 109` produced
`/etc/default/dropbear` with `DROPBEAR_PORT=143` and
`DROPBEAR_EXTRA_ARGS="-K 5 -p 109"`. A real SSH tunnel through port 143 worked.

```
      PUERTOS: 109 143
[1] REDEFINIR PUERTOS                  set ports again
[2] CONFIGURACION MANUAL (nano)        edit /etc/default/dropbear
[3] FIX DE INICIO CON EL SISTEMA [OFF] start-at-boot fix
[4] CONFIGURAR BANNER SSH
[5] ESTADO DEL SERVICIO  [6] REINICIAR SERVICIO  [7] INICIAR/DETENER SERVICIO [ON]
[0] VOLVER   [8] DESINSTALAR DROPBEAR
```

### 3.3 SOCKS Python 🔬

Opening it the first time installs `python2.7` and generates four proxy modules
in `/root/ADMRufu/socksPY` (`PPub2/3`, `PDirect2/3`).

```
      PUERTOS: 8080
[1] SOCKS PYTHON2 SIMPLE  [OFF]
[2] SOCKS PYTHON3 SIMPLE  [OFF]
[3] SOCKS PYTHON2 DIRECTO [OFF]
[4] SOCKS PYTHON3 DIRECTO [ON]
[5] REINSTALAR MODULOS PYTHON
[6] ESTADO DE SERVICIOS            (appears once a port exists)
[7] DETENER TODO LOS PUERTO Y SERVICIOS   stop all ports
[0] VOLVER   [8] LOGS Y REGISTROS
```

- **Direct** (🔬): asks for the listen port, the target port (from the
  service list), the response status (`Enter` = 200, `101` for WebSocket), an
  optional custom header and a "mini-banner". It creates
  `python.<port>.service` running
  `python3 PDirect3.pyc -l <target> -p <port> -r <status>` as root. A request
  with `Upgrade: websocket` got `HTTP/1.1 101 Switching Protocols`, then the
  default extra header `HTTP/1.1 200 Connection Established`, then the Dropbear
  banner.
- **Simple / public** (🔬): asks for the port and mini-banner only
  (`PPub3.pyc -p <port>`). It is an HTTP `CONNECT` proxy to any host:
  `CONNECT 127.0.0.1:143` answered `200 Connection Established`.
- Each mode can hold several ports (one service per port).

### 3.4 Stunnel 🔬

Before installation: `[1] INSTALAR STUNNEL`, `[2] CERTIFICADOS SSL` (§4.1).
Install asks for the TLS port and the target port (service list), shows
`DOMINIO: local` when no domain certificate is active, then installs
`stunnel4`. One file per port, `/etc/stunnel/<port>.stunnel.conf`, run by the
distribution's `stunnel@<port>.stunnel` template unit. With no domain
certificate it uses `/root/ADMRufu/certificados/local/local.{crt,key}` (subject
`Stunnel Root CA`).

```
      PUERTOS: 443
[1] AGREGAR UN PUERTO SSL            add a TLS port
[2] MODIFICAR AJUSTES DE UN PUERTO (nano)
[3] ADMINISTRADOR DE CERTIFICADOS SSL
[4] ESTADO DEL SERVICIO SSL  [5] INICIAR/PARAR SERVICIO SSL [ON]  [6] REINICIAR SERVICIO SSL
[7] LOG DEL PROCESO STUNNEL  [8] LOG ... EN TIEMPO REAL
[0] Volver   [9] DESINSTALAR STUNNEL
```

### 3.5 SlowDNS (DNSTT) 🔬

Install asks for the NS domain and the target port (service list), installs
`iptables`, generates a key pair and starts `slowdns.service`:
`dns-server -udp :5300 -privkey-file server.key <ns-domain> 127.0.0.1:<target>`
(a `dnstt-server` build). `ExecStartPost` opens UDP 5300 and adds
`iptables -t nat PREROUTING udp --dport 53 -j REDIRECT --to-ports 5300`.
Files: `/root/ADMRufu/slowdns/{dns-server,server.key,server.pub,slowdns.log}`.

```
 PORT: 5300   REDIRECT: 53 > 5300   TRAFIC PORT: 22
 NS DOMAIN: ns.example.com   CLAVE PUB: <64 hex characters>
[1] RECONFIGURAR SLOWDNS
[2] MIS CLAVES SLOWDNS  [3] GENERAR NUEVO PAR DE CLAVES  [4] PAR DE CLAVES PERSONALES
[5] MODIFICAR PUERTO DE TRAFICO  [6] MODIFICAR DOMINIO NS
[7] ESTADO  [8] REINICIAR  [9] INICIAR/PARAR [ON]
[10] LOG SLOWDNS  [11] LOG EN TIEMPO REAL
[0] Volver  [12] REINSTALAR  [13] DESINSTALAR
```

DNS traffic from a real client was not tested (📦 needs a public NS record).

### 3.6 WS-EPRO 🔬

Asks for the listen port and the target port; writes
`/root/ADMRufu/ws-epro/config.yml` (`listen: - target_host, listen_port,
target_port`) and starts `ws-epro.service` (a closed-source binary). It answered
a WebSocket request with `101 Switching Protocols` followed directly by the
target's SSH banner. Menu: reconfigure, status, restart, start/stop, log,
live log, reinstall, uninstall.

### 3.7 UDP-Custom 🔬

Asks for the UDP port (default 36712) and an iptables port range (default
`1:65535`). Runs the closed-source `udp-custom` binary with
`config.json` (`listen`, buffer sizes, `"auth": {"mode": "passwords"}`). Its
unit adds `iptables -t nat PREROUTING -i eth0 -p udp --dport 1:65535 -j DNAT
--to-destination :36712` (IPv4 and IPv6), i.e. **every incoming UDP port** on
`eth0` is redirected to UDP-Custom by default. Menu: reconfigure, change port,
change iptables range, status, restart, start/stop, log, live log, reinstall,
uninstall. Client traffic was not tested.

### 3.8 UDP-Hysteria 🔬

Asks for the version (`[1] HYSTERIA VERSION 1`, `[2] HYSTERIA VERSION 2`), the
UDP port (default 36712; a port in use is rejected by re-asking) and an iptables
range for port hopping (default `1:65535`). Version 2 produced
`/root/ADMRufu/udp-hysteria/config.yaml` with:

- TLS from the `local` certificate (or the active domain certificate);
- `auth: type: command`, `command: …/autSSH`: **clients log in with an SSH
  panel account** `user:password` (tested: correct password → exit 0,
  wrong → exit 1);
- Salamander obfuscation **on by default** with a random 8-character password;
- QUIC window sizes;
- a DNAT rule from the chosen range to the port.

The binary reports `Version: v2.2.2`. Menu shows version, port, redirect range
and obfs password, with reconfigure, change obfs, status, restart, start/stop,
log, live log, reinstall, uninstall.

### 3.9 BadVPN-UDPGW 🔬

Asks for the port (default 7300). Unit `badvpn-udpgw.<port>.service`:
`badvpn-udpgw --listen-addr 127.0.0.1:<port> --max-clients 1000
--max-connections-for-client 10`. Menu: add port, remove port, reconfigure,
status, restart, start/stop, log (with size), reinstall, uninstall.

### 3.10 Squid 🔬

Asks for several ports and installs the distribution package. `squid.conf` is
replaced by includes of `/root/ADMRufu/Squid/{acl,access,ports,caching,hostname}.conf`.
`access.conf` ends with `http_access allow all`, so **it is an open proxy**
(tested: it fetched an external site). ACLs for a denied-domain list and a
denied-regex list are included. Menu: add port, remove port, reconfigure, edit
ACL / access / ports / caching / hostname, reload, status, restart,
start/stop, connection log, cache/error log, uninstall.

### 3.11 OpenVPN 🔬

Asks for the transport (`TCP`/`UDP`), port (default 1194), cipher
(`AES-128/192/256-CBC`, `AES-128/192/256-GCM`) and DNS (Cloudflare, Google,
OpenDNS, Verisign, Quad9, Quad9 uncensored, UncensoredDNS, FDN, DNS.Watch,
Yandex basic, AdGuard, NextDNS). It builds a CA with easy-rsa and starts
`openvpn@server`. **Clients log in with SSH panel accounts**: the server uses
`plugin openvpn-plugin-auth-pam.so login`, `verify-client-cert none` and
`username-as-common-name`; the client file uses `auth-user-pass`. Subnet
`10.8.0.0/24`, `redirect-gateway`, `auth SHA512`, `tls-auth`. One shared client
file (`/etc/openvpn/client/OpenVPN.ovpn`), printed in full by
*VER CLIENTE OVPN*. Menu: view client, reconfigure client, regenerate RSA keys,
reconfigure OpenVPN, edit client / server config (nano), status, restart,
start/stop, log, live log, reinstall, uninstall. No client connection was made
(📦 needs a TUN device on a VPS).

### 3.12 Checkuser 🔬

Asks for a port, the time base (`UTC` or the system time zone) and the date
format (`DDMMYYYY` or epoch seconds). Runs `checkuser --port <port>` (closed
source). Tested API:

- `GET /` → the number of online connections (plain text);
- `POST /checkuser` with JSON `{"user":"<name>"}` → the expiry date
  (`11112026`).

The menu shows `URL CHECKUSER: http://<server-ip>:<port>/checkuser` and
`URL ONLINES: http://<server-ip>:<port>`, plus status, restart, start/stop,
log, live log, clear log, uninstall.

### 3.13–3.19 Closed-source tunnel servers ✅

ATKEN and HASH (`AUTENTIFICADOR TOKEN EN LINEA`), FILEBROWSER, SSHGO, HCR CUSTOM
and BHTTP TUNNEL each show only `[1] INSTALAR …` before installation. They were
not installed. FileBrowser is a third-party open-source web file manager; the
others are proprietary binaries shipped by ADMRufu.

### 3.15 V2Ray / Xray 🔬

**Install wizard:** NOMBRE (inbound name, random default) → core
(`[1] V2RAY`, `[2] XRAY`) → port → protocol (`VMESS`, `VLESS`, `SOCKS`,
`TROJAN`, `SHADOWSOCKS`) → network (for VLESS: `TCP`, `GRPC`, `WEBSOCKET`,
`XHTTP`) → for TCP: `ACTIVAR CAMUFLAJE HTTP? [S/N]` (HTTP header camouflage),
`ABILITAR FALLBACKS? [S/N]`, `NGINX PARA PROTOCOLOS GRPC [S/N]`; for XHTTP: a
random path, accept or type one → `TLS CLOSE` / `TLS OPEN` → summary with
`DOMINIO: local` → `[0] CANCELAR [1] REINTENTAR [2] APLICAR`. **No REALITY
option was offered** on any path tried.

It downloads both V2Ray and Xray into `/root/ADMRufu/v2ray/bin/`, then runs
**one systemd instance per inbound**: `xray@<port>` with
`/root/ADMRufu/v2ray/conf/config.<port>.json`. Each config has the stats API
(`dokodemo-door` on 127.0.0.1), per-user traffic counters, logs in
`/root/ADMRufu/v2ray/log/`, and a routing rule that blocks private and
reserved IP ranges. TLS uses the `local` certificate unless a domain
certificate is active.

```
[1] AGREGAR PROTOCOLO V2RAY/XRAY      add an inbound (same wizard)
[2] QUITAR PROTOCOLO V2RAY/XRAY       remove an inbound
[3] VER CONFIGIRACION JSON            view JSON
[4] EDITAR CONFIGIRACION JSON (nano)  edit JSON
[5] CONTROL DE TRFICO [OFF]           traffic accounting (rayStats timer every 30 s)
[6] LOG ACCESS/ERROR <size>  [7] LOG EN TIEMPO REAL  [8] TODO EL LOG
[9] ESTADO DEL SERVICIO  [10] REINICIAR SERVICIO  [11] INICIAR/PARAR SERVICIOS [ON]
[0] Volver   [12] RECONFIGURAR   [13] DESINSTALAR
```

#### 3.15b Manage accounts (V2Ray/Xray) 🔬

```
[1] NUEVO USUARIO   [2] ELIMINAR USUARIO   [3] RENOVAR USUARIO
[4] INFORMACION DE USUARIOS   [5] RESET TRAFFIC STATS
```

*New user* first asks which inbound (`xray vless tcp tls 10443`,
`xray vless xhttp 10444`), then NOMBRE, UUID (generated with `uuidgen`;
⚠️ **`uuidgen` was not installed, so the default was empty** and a UUID had to
be typed) and EXPIRA EN (days). It prints a share link and offers the client
JSON (`Ver cliente json? [S/N]`), which includes a local SOCKS inbound on 1080.
Users are written into the inbound's `clients` (with `email` = name) and to
`/root/ADMRufu/v2ray/users/<name>.<core>.<protocol>.<tag>.json`
(`uuid`, `nombre`, `expira` as epoch seconds, `level`, `protocol`, `ray`, `tag`).
*User information* lists `NAME EXP REMAIN UUID STATUS` and reprints the link.
Real traffic through the VLESS+XHTTP inbound with the official Xray client
returned HTTP 200 (🔬). Defects seen: the share link drops the leading `/` of
the XHTTP path, and in *User information* the path is empty; `alpn=h2` is added
even without TLS. No QR code is offered.

### 3.17 WireGuard 🔬

Asks for the UDP port (default 51820), installs `wireguard` and `qrencode`, and
starts `wg-iptables.service` (enables IP forwarding, SNATs `10.7.0.0/24` to the
**public IP**, opens the port) and `wg-quick@wg0` (server `10.7.0.1/24`).

```
  PORT: 51820
[1] MODIFICAR PUERTO WG  [2] MODIFICAR CONFIGURACION (NANO)
[3] FIX IP NAT [OFF]                   (for servers behind NAT)
[4] ESTADO  [5] REINICIAR  [6] INICIAR/PARAR [ON]
[0] Volver  [7] REINSTALAR  [8] DESINSTALAR
```

#### 3.17b Manage accounts (WireGuard) 🔬

`[1] NUEVO CLIENTE WIREGUARD`, `[2] REMOVER CLIENTE WIREGUARD`,
`[3] VER LISTA DE CLIENTE WIREGUARD`. *New client* asks for a name, prints the
client config (address `10.7.0.N/24`, DNS 8.8.8.8/8.8.4.4, preshared key,
`AllowedIPs 0.0.0.0/0`, keepalive 25), then offers a QR code and an
"HTTP Custom v2ray" JSON. Client files are kept under
`/etc/wireguard/{client,peers,serv}` (mirrored in `/root/ADMRufu/wireguard`).

## 4. Extra tools 🔬

```
[1] ADMINISTRADOR DE CERTIFICADOS SSL       §4.1
[2] ADMINISTRADOR BANNER SSH/DROPBEAR       same as §3.1a
[3] CONFIGURAR CLAVE Y ACCESO ROOT          same as §3.1b
[4] ACELERACION DEL KERNEL                  §4.4
[5] MANTENIMIENTO DEL SYSTEMA (RAM/DISCO)   §4.5
[6] BLOQUEO DE TORRENT, PUERTOS Y PALABRAS CLAVES   §4.6
[7] ADMINISTRADOR FAIL2BAN                  §4.7
[8] PROTECCION DDOS                         §4.8
[9] MODIFICAR ZONA HORARIA                  time zone (📦 the list was empty in the container)
[10] SPEEDTEST OOKLA                        installs Ookla's repository and `speedtest`, runs a test (🔬)
[11] PLUGINS SCRIPT                         §4.11
[0] Volver
```

### 4.1 SSL certificates 🔬

First `[1] INSTALAR ADMINISTRADOR ACME.SH` (installs `netcat`, `socat` and
acme.sh into `/root/.acme.sh`). Then the screen lists certificates
(`<domain>  Exp: N days`) with `[1] ADMINISTRAR CERTIFICADOS`,
`[2] AGREGAR UN NUEVO CERTIFICADO SSL`, `[3]` uninstall acme.sh. *Add* offers
`Let's Encrypt`, `ZeroSSL`, `Mode Manual` (asks the domain, then opens nano for
the certificate and then the key, stored in `/root/.acme.sh/<domain>_ecc/`)
and `Url link (.zip)`. A certificate's page shows its expiry and
`Status: inactive|active` with `[1] REMOVER` and `[2] ACTIVAR` (activate =
the certificate other protocols use). Let's Encrypt could not be completed in
the container (📦).

### 4.4 Kernel acceleration ✅ 📦

Shows the active congestion control (`cubic`) and lists the algorithms the
kernel offers to switch to. In the container only `reno` was listed.

### 4.5 System maintenance ✅

A two-column RAM/disk box (total, used, free, buffer, cache / total, used,
available, free) and `[1] LIMPIAR RAM/CACHE`, `[2] LIMPIAR DISCO/CACHE`,
`[3] TAREAS PROGRAMADAS [OFF]` (scheduled tasks).

### 4.6 Torrent, port and keyword blocking 🔬

```
[1] BLOUEAR PALABRAS CLAVES Y TORRENT [OFF]   keyword/torrent blocking
[2] BLOQUEAR PUERTOS SAPAM [OFF]              spam-port blocking
[3] VER REGLAS DE PALABRAS BLOQUEADAS         view rules (appears when ON)
[4] MODIFICAR LISTA DE PALABRAS BLOQUEADAS
[5] MODIFICAR LISTA DE PUERTOS BLOQUEADOS
[6] AUTO INICIAR CON EL SISTEMA [OFF]
```

Enabling [1] added 16 `iptables -A OUTPUT -m string --string "<word>" --algo bm
-j DROP` rules (comment `spamTXT`; words such as `peer_id=`, `info_hash`,
`announce`, `BitTorrent`, `magnet:`). They apply to **all** outgoing traffic of
the server, not only to tunnel users.

### 4.7 Fail2ban 🔬

`[1] INSTALAR FAIL2BAN` installs the package and writes
`jail.d/sshd.conf` (`[sshd]`, `bantime = 5m`, `findtime = 1m`,
`maxretry = 3`, `logpath = /var/log/auth.log`). Menu: change ban time, change
find period, change attempts, edit manually (nano), status, start/stop, log,
uninstall. 📦 The service showed OFF in the container (no `auth.log`).

### 4.8 DDoS protection 🔬 ⚠️

Install asks for ports to monitor, maximum attempts, block time in minutes and
an IP whitelist (prefilled with 127.0.0.1 and the server IP); writes
`/root/ADMRufu/ddos/config.txt` (`puertos`, `maxIntentos`, `tiempoBloqueo`,
`listaBlanca`, `iface`) and starts `ddos.service`. **The service crash-looped:
`libpcap.so.0.8` was missing**, while the menu still showed `[ON]`. Menu:
status, restart, start/stop, log, live log, reinstall, uninstall.

### 4.11 Plugins 🔬

Lets the admin create small named shell scripts that become commands in the
terminal: create, delete, enable/disable, make executable, delete all, back
up, restore, help.

## 5. API and bots 🔬

```
[1] INSTALADOR DE API          [2] INSTALADOR DE BOT TELEGRAM
[3] INSTALADOR DE BOT WHATSAPP (warns that it uses a lot of resources)
```

The API (`apiAccess.service`, closed source) listens on the Unix socket
`/tmp/admAPI.sock`, used as `echo '/help' | nc -U /tmp/admAPI.sock`.
Commands: `/server list|active|set|add|remove`,
`/ssh list|info|add|remove|set`, `/token …`, `/hwid …`; a server must be
configured with `/server` first. The bots were not installed (❔).

## 6. Script settings 🔬

```
[1] CONTADOR DE CONECCIONES Y CUENTAS [ON]   account counters on the dashboard
[2] INFORMACION DEL SISTEMA [ON]             OS / IP / date / time box
[3] INFORMACION DE DISCO Y CPU [OFF]
[4] INFORMACION DE MEMORIA RAM [OFF]
[5] INFORMACION DE MEMORIA SWAP [OFF]
[6] AUTO-INICIAR SCRIPT [OFF]                open the panel at login
```

Each toggle adds or removes a block of the main-menu header (layout in
"Main-menu header" above).

## What could not be observed

- Real client traffic for SlowDNS, UDP-Custom, OpenVPN and WireGuard (the
  container has no public NS record and no TUN/WireGuard kernel path tested).
- Hysteria version 1, the Dropbear "FIX" and "MOD" variants, the closed-source
  tunnel servers (§3.13–3.19), the Telegram and WhatsApp bots, the TOKEN account
  mode and how HTTP Custom authenticates in HWID mode.
- Reboot (`REINICIAR VPS`) and the full uninstall.

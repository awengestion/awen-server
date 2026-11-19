#!/usr/bin/env bash
# Servidor AWEN en Ubuntu / Debian (amd64).
#
#   curl -fsSL https://raw.githubusercontent.com/awengestion/awen-server/main/instalar-linux.sh | sudo bash
#
# Instala Docker (repositorio oficial) si falta, crea /opt/awen, escribe el docker-compose.yml
# (la misma imagen que TrueNAS), opcionalmente suma Tailscale para el acceso remoto, deja un
# timer diario de actualización y muestra el código de alta para el primer administrador.
#
# Opciones (con curl: `| sudo bash -s -- <opciones>`):
#   --tailscale-clave tskey-auth-...   clave de Tailscale sin preguntar
#   --tailscale-nombre awen-servidor   nombre del servidor en Tailscale
#   --sin-tailscale                    solo red local, sin preguntar
#   --actualizar                       baja la última versión y reinicia (no toca datos)
#   --auto-actualizar si|no            activa o apaga la actualización diaria
#   --estado                           contenedores, actualización diaria y código de alta
#   --desinstalar [--borrar-datos]     baja AWEN; los datos quedan salvo --borrar-datos
#
# Volver a correrlo sobre una instalación existente solo actualiza: no pisa datos ni la
# configuración.

set -euo pipefail

# Todo dentro de main: con `curl | bash` una descarga cortada no ejecuta medio script.
main() {
    local DIR=/opt/awen
    local COMPOSE="$DIR/docker-compose.yml"
    local ENVFILE="$DIR/.env"
    local IMAGEN=ghcr.io/awengestion/awen-server:latest
    local UID_AWEN=568
    local PUERTO=3501

    local accion=instalar usar_ts=0 ts_clave="" ts_nombre="" sin_ts=0 borrar_datos=0 auto=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --tailscale-clave) ts_clave="${2:-}"; shift ;;
            --tailscale-nombre) ts_nombre="${2:-}"; shift ;;
            --sin-tailscale) sin_ts=1 ;;
            --actualizar) accion=actualizar ;;
            --auto-actualizar) accion=auto; auto="${2:-}"; shift ;;
            --estado) accion=estado ;;
            --desinstalar) accion=desinstalar ;;
            --borrar-datos) borrar_datos=1 ;;
            -h|--help) sed -n '2,22p' "$0" 2>/dev/null || true; exit 0 ;;
            *) error "Opción desconocida: $1" ;;
        esac
        shift
    done

    [ "$(id -u)" -eq 0 ] || error "Correr como root (sudo)."

    case "$accion" in
        actualizar) requiere_instalado; actualizar; exit 0 ;;
        auto) requiere_instalado; auto_actualizar "$auto"; exit 0 ;;
        estado) requiere_instalado; estado; exit 0 ;;
        desinstalar) desinstalar; exit 0 ;;
    esac

    verificar_sistema

    if [ -f "$COMPOSE" ]; then
        info "AWEN ya está instalado en $DIR: se actualiza sin tocar datos ni configuración."
        instalar_docker
        instalar_timer
        actualizar
        mostrar_acceso
        exit 0
    fi

    instalar_docker
    revisar_puertos
    elegir_tailscale
    crear_carpetas
    escribir_compose
    abrir_firewall

    info "Bajando la imagen de AWEN (la primera vez tarda unos minutos)..."
    (cd "$DIR" && docker compose pull -q && docker compose up -d)

    [ "$usar_ts" -eq 1 ] && esperar_tailscale
    instalar_timer
    esperar_awen
    mostrar_acceso
}

# --- Mensajes ---------------------------------------------------------------

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
aviso() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
error() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# Con `curl | bash` la entrada estándar es el script: las preguntas van por la terminal.
preguntar() {
    local texto="$1" respuesta=""
    if [ -r /dev/tty ]; then
        read -r -p "$texto" respuesta < /dev/tty || true
    fi
    printf '%s' "$respuesta"
}

requiere_instalado() {
    [ -f "$COMPOSE" ] || error "AWEN no está instalado en $DIR."
}

# --- Sistema ----------------------------------------------------------------

verificar_sistema() {
    [ -r /etc/os-release ] || error "No se encontró /etc/os-release."
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) ;;
        *) error "Sistema no soportado (${PRETTY_NAME:-desconocido}). AWEN se instala en Ubuntu o Debian." ;;
    esac
    case "${ID}:${VERSION_ID:-}" in
        ubuntu:22.04|ubuntu:24.04|ubuntu:26.04|debian:12|debian:13) ;;
        *) aviso "${PRETTY_NAME} no está probado (sí Ubuntu 22.04/24.04/26.04 y Debian 12/13). Se sigue igual." ;;
    esac
    OS_ID="$ID"
    OS_CODENAME="${VERSION_CODENAME:-}"
    [ -n "$OS_CODENAME" ] || error "No se pudo determinar la versión de ${PRETTY_NAME}."

    local arq
    arq="$(dpkg --print-architecture)"
    [ "$arq" = amd64 ] || error "Arquitectura $arq no soportada: AWEN necesita un equipo de 64 bits (amd64)."

    command -v systemctl >/dev/null || error "Se necesita systemd."

    # El certificado HTTPS y Tailscale fallan con la hora corrida
    if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo no)" != yes ]; then
        aviso "La hora del equipo no está sincronizada. Revisar con: timedatectl"
    fi
}

instalar_docker() {
    if command -v docker >/dev/null; then
        case "$(readlink -f "$(command -v docker)")" in
            /snap/*) error "Docker está instalado como snap, que no da acceso a las carpetas ni a la red que usa AWEN. Quitarlo (snap remove docker) y volver a correr este script." ;;
        esac
        if ! docker compose version >/dev/null 2>&1; then
            info "Instalando el plugin de Docker Compose..."
            apt-get update -qq
            apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 \
                || apt-get install -y -qq docker-compose-v2 >/dev/null 2>&1 \
                || error "Docker está instalado pero falta 'docker compose' y no se pudo instalar. Instalar Docker desde https://docs.docker.com/engine/install/"
        fi
        systemctl enable --now docker >/dev/null 2>&1 || true
        return
    fi

    info "Instalando Docker desde el repositorio oficial..."
    export DEBIAN_FRONTEND=noninteractive
    # needrestart (Ubuntu) llena la pantalla con su resumen después de cada apt
    export NEEDRESTART_SUSPEND=1
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl >/dev/null
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
    systemctl enable --now docker >/dev/null 2>&1
}

revisar_puertos() {
    local p
    for p in 3500 3501 5433; do
        if ss -Hltn "sport = :$p" 2>/dev/null | grep -q .; then
            error "El puerto $p ya está en uso por otro programa (ver: ss -ltnp 'sport = :$p'). AWEN lo necesita libre."
        fi
    done
}

# --- Tailscale --------------------------------------------------------------

elegir_tailscale() {
    if [ "$sin_ts" -eq 1 ]; then ts_clave=""; return; fi

    # Reinstalación sobre datos que quedaron: el equipo ya está dado de alta en Tailscale
    if [ -z "$ts_clave" ] && [ -s "$DIR/tailscale/tailscaled.state" ]; then
        local r
        r="$(preguntar 'Este equipo ya estaba conectado a Tailscale. ¿Mantener el acceso remoto? [S/n]: ')"
        case "$r" in
            n|N|no|NO) ;;
            *)
                ts_nombre="${ts_nombre:-$(sed -n 's/^TS_HOSTNAME=//p' "$ENVFILE" 2>/dev/null)}"
                ts_nombre="${ts_nombre:-awen-servidor}"
                usar_ts=1
                verificar_tun
                return ;;
        esac
    fi

    if [ -z "$ts_clave" ]; then
        echo
        echo "Acceso remoto (opcional): con Tailscale los puestos y el celular entran desde fuera"
        echo "del taller, y funciona el webhook de WhatsApp. Hace falta una clave de"
        echo "https://login.tailscale.com/admin/settings/keys (Enter para omitir)."
        ts_clave="$(preguntar 'Clave de Tailscale (tskey-auth-...): ')"
        ts_clave="${ts_clave//[[:space:]]/}"
        [ -n "$ts_clave" ] || { info "Sin Tailscale: AWEN queda solo en la red local."; return; }
    fi

    # Solo letras, números y guiones: va a .env, que Compose interpreta
    [[ "$ts_clave" =~ ^tskey-auth-[A-Za-z0-9-]+$ ]] || error "Clave de Tailscale inválida: empieza con tskey-auth- y no lleva espacios."

    usar_ts=1
    verificar_tun

    while :; do
        if [ -z "$ts_nombre" ]; then
            ts_nombre="$(preguntar 'Nombre del servidor en Tailscale [awen-servidor]: ')"
            ts_nombre="${ts_nombre:-awen-servidor}"
        fi
        if [[ "$ts_nombre" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then break; fi
        aviso "Solo minúsculas, números y guiones, sin espacios."
        ts_nombre=""
        [ -r /dev/tty ] || error "Nombre de Tailscale inválido."
    done
}

verificar_tun() {
    if systemctl is-active --quiet tailscaled 2>/dev/null; then
        error "Este equipo ya tiene Tailscale instalado. AWEN trae el suyo en un contenedor y no pueden convivir: desinstalar el del sistema o volver a correr con --sin-tailscale."
    fi
    [ -c /dev/net/tun ] || error "Falta /dev/net/tun (necesario para Tailscale). En una VM o contenedor LXC hay que habilitarlo."
}

esperar_tailscale() {
    info "Conectando con Tailscale..."
    local i
    for i in $(seq 1 60); do
        if docker exec awen-tailscale tailscale --socket /var/run/tailscale/tailscaled.sock status --json 2>/dev/null \
            | grep -q '"BackendState": *"Running"'; then
            # La clave solo sirve el primer arranque: se borra del disco
            sed -i 's/^TS_AUTHKEY=.*/TS_AUTHKEY=/' "$ENVFILE"
            (cd "$DIR" && docker compose up -d >/dev/null 2>&1)
            info "Tailscale conectado."
            return
        fi
        sleep 2
    done
    aviso "Tailscale no conectó en 2 minutos. Ver: docker logs awen-tailscale (clave vencida o ya usada)."
}

# --- Archivos ---------------------------------------------------------------

crear_carpetas() {
    install -d -m 755 "$DIR"
    install -d -m 700 -o "$UID_AWEN" -g "$UID_AWEN" "$DIR/awen"
    if [ "$usar_ts" -eq 1 ]; then
        install -d -m 700 "$DIR/tailscale"
        install -d -m 750 -o "$UID_AWEN" -g "$UID_AWEN" "$DIR/tailscale-sock"
    fi
}

escribir_compose() {
    umask 077
    if [ "$usar_ts" -eq 1 ]; then
        printf 'TS_AUTHKEY=%s\nTS_HOSTNAME=%s\n' "$ts_clave" "$ts_nombre" > "$ENVFILE"
    else
        : > "$ENVFILE"
    fi
    chmod 600 "$ENVFILE"

    {
        cat <<EOF
# AWEN servidor. Generado por instalar-linux.sh: los datos viven en $DIR/awen.
# Actualizar: sudo systemctl start awen-actualizar (o se hace solo una vez por día).
services:
  awen-server:
    image: $IMAGEN
    container_name: awen-server
    network_mode: host
    restart: unless-stopped
    stop_grace_period: 60s
EOF
        if [ "$usar_ts" -eq 1 ]; then
            cat <<'EOF'
    environment:
      AWEN_TS_SERVE_CONFIG: /var/run/tailscale/serve.json
EOF
        fi
        cat <<EOF
    volumes:
      - $DIR/awen:/var/lib/awen-server
      - /etc/machine-id:/etc/machine-id.host:ro
EOF
        if [ "$usar_ts" -eq 1 ]; then
            cat <<EOF
      - $DIR/tailscale-sock:/var/run/tailscale

  # Acceso remoto: https://<TS_HOSTNAME>.<red>.ts.net/ y webhook de WhatsApp por Funnel (8443)
  tailscale:
    image: tailscale/tailscale:stable
    container_name: awen-tailscale
    network_mode: host
    restart: unless-stopped
    cap_add: [NET_ADMIN, NET_RAW]
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      TS_AUTHKEY: \${TS_AUTHKEY:-}
      TS_HOSTNAME: \${TS_HOSTNAME}
      TS_STATE_DIR: /var/lib/tailscale
      TS_SOCKET: /var/run/tailscale/tailscaled.sock
      TS_AUTH_ONCE: "true"
      TS_ACCEPT_DNS: "false"
      TS_USERSPACE: "false"
      TS_SERVE_CONFIG: /var/run/tailscale/serve.json
    volumes:
      - $DIR/tailscale:/var/lib/tailscale
      - $DIR/tailscale-sock:/var/run/tailscale
EOF
        fi
    } > "$COMPOSE"
    chmod 600 "$COMPOSE"
    umask 022
}

abrir_firewall() {
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
        info "Firewall ufw activo: se abre el puerto $PUERTO para los puestos."
        ufw allow "$PUERTO/tcp" comment 'AWEN puestos' >/dev/null
    fi
}

# --- Actualización ----------------------------------------------------------

escribir_actualizador() {
    cat > "$DIR/awen-actualizar.sh" <<EOF
#!/usr/bin/env bash
# Baja la última versión de AWEN (y de Tailscale si está) y reinicia lo que cambió.
# Los datos en $DIR/awen no se tocan. Lo corre el timer awen-actualizar una vez por día.
set -euo pipefail
cd $DIR
antes=\$(docker compose images -q 2>/dev/null | sort -u)
docker compose pull -q
docker compose up -d --remove-orphans
despues=\$(docker compose images -q 2>/dev/null | sort -u)
# Imágenes que dejaron de usarse (solo las de AWEN; si otra cosa las usa, no se borran)
for img in \$antes; do
    echo "\$despues" | grep -qx "\$img" || docker rmi "\$img" >/dev/null 2>&1 || true
done
echo "AWEN: \$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' awen-server 2>/dev/null || echo '?')"
EOF
    chmod 700 "$DIR/awen-actualizar.sh"
}

instalar_timer() {
    escribir_actualizador
    cat > /etc/systemd/system/awen-actualizar.service <<EOF
[Unit]
Description=Actualizar AWEN
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$DIR/awen-actualizar.sh
EOF
    cat > /etc/systemd/system/awen-actualizar.timer <<'EOF'
[Unit]
Description=Actualizar AWEN una vez por día

[Timer]
OnCalendar=*-*-* 04:00
RandomizedDelaySec=2h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    # Respeta si alguien la apagó con --auto-actualizar no
    if [ ! -f "$DIR/.sin-auto-actualizar" ]; then
        systemctl enable --now awen-actualizar.timer >/dev/null 2>&1
    fi
}

actualizar() {
    [ -x "$DIR/awen-actualizar.sh" ] || escribir_actualizador
    info "Actualizando AWEN..."
    "$DIR/awen-actualizar.sh"
}

auto_actualizar() {
    case "$1" in
        si|sí)
            rm -f "$DIR/.sin-auto-actualizar"
            instalar_timer
            info "Actualización diaria activada (entre las 4 y las 6)." ;;
        no)
            touch "$DIR/.sin-auto-actualizar"
            systemctl disable --now awen-actualizar.timer >/dev/null 2>&1 || true
            info "Actualización diaria apagada. Para actualizar a mano: sudo $DIR/awen-actualizar.sh" ;;
        *) error "Usar --auto-actualizar si  o  --auto-actualizar no" ;;
    esac
}

# --- Estado y acceso --------------------------------------------------------

ip_local() {
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}'
}

esperar_awen() {
    info "Esperando que AWEN cree la base de datos..."
    local i
    for i in $(seq 1 150); do
        [ -s "$DIR/awen/CODIGO-ALTA.txt" ] && return
        if curl -fsk "https://127.0.0.1:$PUERTO/api/v1/health" >/dev/null 2>&1 && [ "$i" -gt 15 ]; then
            return
        fi
        sleep 2
    done
    aviso "AWEN todavía no respondió. Ver: docker logs awen-server"
}

mostrar_acceso() {
    local ip
    ip="$(ip_local)"
    echo
    info "Servidor AWEN en https://${ip:-IP-DEL-SERVIDOR}:$PUERTO"
    if [ -s "$DIR/awen/CODIGO-ALTA.txt" ]; then
        echo
        echo "    Código de alta: $(tr -d '[:space:]' < "$DIR/awen/CODIGO-ALTA.txt")"
        echo
        echo "    En el primer puesto: instalar AWEN, elegir \"Puesto\", conectarlo a la"
        echo "    dirección de arriba e ingresar este código para crear el administrador."
        echo "    Se puede volver a ver con: sudo cat $DIR/awen/CODIGO-ALTA.txt"
    fi
    if [ -f /etc/systemd/system/awen-actualizar.timer ] && systemctl is-enabled --quiet awen-actualizar.timer 2>/dev/null; then
        echo
        echo "    Se actualiza solo una vez por día. Apagarlo: ... | sudo bash -s -- --auto-actualizar no"
    fi
    echo
}

estado() {
    (cd "$DIR" && docker compose ps)
    echo
    if systemctl is-enabled --quiet awen-actualizar.timer 2>/dev/null; then
        systemctl list-timers awen-actualizar.timer --no-pager | head -2
    else
        echo "Actualización diaria: apagada"
    fi
    mostrar_acceso
}

# --- Desinstalar ------------------------------------------------------------

desinstalar() {
    if [ -f "$COMPOSE" ]; then
        info "Bajando AWEN..."
        (cd "$DIR" && docker compose down --rmi all) || true
    fi
    systemctl disable --now awen-actualizar.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/awen-actualizar.service /etc/systemd/system/awen-actualizar.timer
    systemctl daemon-reload

    if [ "$borrar_datos" -eq 1 ]; then
        aviso "Se borran TODOS los datos de AWEN en $DIR (base, fotos, backups, licencia)."
        local r
        r="$(preguntar 'Escribir BORRAR para confirmar: ')"
        [ "$r" = BORRAR ] || error "Cancelado: los datos quedan en $DIR."
        rm -rf "$DIR"
        info "AWEN desinstalado y datos borrados."
    else
        rm -f "$COMPOSE" "$DIR/awen-actualizar.sh"
        info "AWEN desinstalado. Los datos quedan en $DIR (la clave de Tailscale ya no está en disco)."
        info "Al volver a instalar, se retoman esos datos."
    fi
}

main "$@"

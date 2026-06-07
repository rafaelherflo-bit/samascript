#!/bin/bash

# 1. VERIFICACIÓN DE PERMISOS
[[ $EUID -ne 0 ]] && {
    log_error "Se requiere sudo."
    exit 1
}

# --- CONFIGURACIÓN Y COLORES ---
CONFIG_FILE="/etc/samascript/config.json"
LOG_FILE="/var/log/samascript.log"
CUSTOM_PORTS="/etc/apache2/custom_ports.conf"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; }

clear
echo -e "${BLUE}===================================================="
echo -e "       SAMASCRIPT V7.4 - ENTERPRISE EDITION         "
echo -e "====================================================${NC}"

# --- 2. VALIDACIÓN JSON Y DEPENDENCIAS ---
log_info "Validando configuración y dependencias..."

if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Falta $CONFIG_FILE"
    exit 1
fi

# Instalación rápida de JQ si falta para poder validar el JSON
if ! command -v jq &>/dev/null; then apt-get update -qq && apt-get install -y jq &>/dev/null; fi

# A. Validar Puertos Duplicados
DUPLICATED_PORTS=$(jq -r '.proyectos[].puerto' "$CONFIG_FILE" | sort | uniq -d)
[ -n "$DUPLICATED_PORTS" ] && {
    log_error "Puertos duplicados: $DUPLICATED_PORTS"
    exit 1
}

# Liberar puerto 80 por defecto para evitar colisiones
if [ -f /etc/apache2/sites-enabled/000-default.conf ]; then
    a2dissite 000-default.conf &>/dev/null
fi

# Liberar puerto 443 por defecto para evitar colisiones
if [ -f /etc/apache2/sites-enabled/default-ssl.conf ]; then
    a2dissite default-ssl.conf &>/dev/null
fi

# B. Validar Integridad de Identidades y Colisiones
log_info "Validando integridad de identidades..."

# 1. Extraer todas las listas para validaciones cruzadas
ADMIN_USERS=$(jq -r '.adminsamas[].usuario' "$CONFIG_FILE" | sort)
PROJ_NAMES=$(jq -r '.proyectos[].nombre' "$CONFIG_FILE" | sort)
DEV_USERS=$(jq -r '.proyectos[].desarrolladores[].usuario' "$CONFIG_FILE" | sort)

# 2. Validar que ningún usuario (Admin o Dev) se llame igual que un Proyecto
# Esto es crítico porque el proyecto crea un GRUPO con ese nombre
COLISION_USER_PROJ=$(echo -e "$ADMIN_USERS\n$DEV_USERS\n$PROJ_NAMES" | sort | uniq -d | grep -xFf <(echo "$PROJ_NAMES"))
if [[ -n "$COLISION_USER_PROJ" ]]; then
    log_error "CONFLICTO CRÍTICO: El nombre '$COLISION_USER_PROJ' se usa como usuario y como proyecto. Esto rompería los permisos de grupo."
    exit 1
fi

# 3. Validar Administradores Duplicados
DUPLICATED_ADMINS=$(echo "$ADMIN_USERS" | uniq -d)
if [[ -n "$DUPLICATED_ADMINS" ]]; then
    log_error "CONFLICTO: Administradores duplicados en el JSON: $DUPLICATED_ADMINS"
    exit 1
fi

# 4. Validar Nombres de Proyecto Duplicados
DUPLICATED_PROJS=$(echo "$PROJ_NAMES" | uniq -d)
if [[ -n "$DUPLICATED_PROJS" ]]; then
    log_error "CONFLICTO: Nombres de proyecto duplicados en el JSON: $DUPLICATED_PROJS"
    exit 1
fi

# 5. Validar Desarrolladores con diferentes contraseñas (Inconsistencia)
# Buscamos si un mismo usuario aparece con contraseñas distintas en diferentes proyectos
INCONSISTENT_PASS=$(jq -r '.proyectos[].desarrolladores[] | "\(.usuario) \(.password)"' "$CONFIG_FILE" | sort | uniq | cut -d' ' -f1 | uniq -d)
if [[ -n "$INCONSISTENT_PASS" ]]; then
    log_error "CONFLICTO: El desarrollador '$INCONSISTENT_PASS' tiene contraseñas diferentes en distintos proyectos."
    exit 1
fi

# Validaciones bandera de dependencias necesarias.
[[ -x "$(command -v mysql)" ]] && MYSQL_READY=true || MYSQL_READY=false
[[ -x "$(command -v php)" ]] && PHP_READY=true || PHP_READY=false
[[ -x "$(command -v apache2)" ]] && APACHE_READY=true || APACHE_READY=false
[[ -d "/usr/share/phpmyadmin" ]] && PMA_READY=true || PMA_READY=false

# Cargar credenciales básicas
MYSQL_ROOT_PW=$(jq -r '.mysql_root_password' $CONFIG_FILE)
PMA_PASS=$(jq -r '.pma_db_pass' $CONFIG_FILE)
ADMIN_DB_USER="admindb"
ADMIN_DB_PASS=$(jq -r '.admin_db_pass' $CONFIG_FILE)

# --- 3. INSTALACIÓN DE COMPONENTES ---
if [ "$MYSQL_READY" = false ] || [ "$PHP_READY" = false ] || [ "$APACHE_READY" = false ] || [ "$PMA_READY" = false ]; then
    log_info "Instalando componentes necesarios..."
    if [ "$PMA_READY" = false ]; then
        echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | debconf-set-selections
        echo "phpmyadmin phpmyadmin/app-password-confirm password $PMA_PASS" | debconf-set-selections
        echo "phpmyadmin phpmyadmin/mysql/admin-pass password $MYSQL_ROOT_PW" | debconf-set-selections
        echo "phpmyadmin phpmyadmin/mysql/app-pass password $PMA_PASS" | debconf-set-selections
        echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | debconf-set-selections
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y acl samba apache2 mariadb-server php libapache2-mod-php ufw lsof phpmyadmin &>/dev/null
fi
log_success "Dependencias listas."

# --- 4. MAPEO DE SEGURIDAD (USUARIOS) ---
log_info "Mapeando seguridad de usuarios..."
PROHIBIDOS="root www-data bin daemon mysql prompt bash git ssh samascript admindb"
TMP_USERS=$(mktemp)
FINAL_USER_LIST=$(mktemp)

jq -r '.adminsamas[]? | "\(.usuario) \(.password)"' "$CONFIG_FILE" >"$TMP_USERS"
jq -r '.proyectos[].desarrolladores[]? | "\(.usuario) \(.password)"' "$CONFIG_FILE" >>"$TMP_USERS"

declare -A PROCESADOS
USER_WHITE_LIST=""

while read -r U P; do
    if echo "$PROHIBIDOS" | grep -qw "$U"; then
        log_error "Usuario '$U' prohibido."
        exit 1
    fi
    if [[ -z "${PROCESADOS[$U]}" ]]; then
        PROCESADOS[$U]="$P"
        echo "$U $P" >>"$FINAL_USER_LIST"
        USER_WHITE_LIST+="$U "
    fi
done <"$TMP_USERS"

MANTENER=$(jq -r '.mantener_usuarios[]?' "$CONFIG_FILE")
USER_WHITE_LIST+="$MANTENER "
GROUP_WHITE_LIST=$(jq -r '.proyectos[].nombre?' "$CONFIG_FILE")

# --- 5. RESET DE PROPIEDAD Y PURGA (SANEAMIENTO) ---
log_info "Saneando /var/www y purgando obsoletos..."

# Reset de propiedad para evitar IDs huérfanos antes de borrar grupos
if [ -d /var/www ]; then
    chown -R root:root /var/www
    chmod -R 755 /var/www
fi

for u in $(awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' /etc/passwd); do
    if ! echo "$USER_WHITE_LIST" | grep -qw "$u"; then
        log_warn "Eliminando usuario: $u"
        userdel -r "$u" 2>/dev/null
        mysql -u root -p"$MYSQL_ROOT_PW" -e "DROP USER IF EXISTS '$u'@'localhost';" 2>/dev/null
    fi
done

for g in $(awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' /etc/group); do
    if ! echo "$GROUP_WHITE_LIST" | grep -qw "$g" && ! echo "$USER_WHITE_LIST" | grep -qw "$g" && [[ "$g" != "adminsamas" ]]; then
        log_warn "Eliminando grupo: $g"
        groupdel "$g" 2>/dev/null
    fi
done

# --- 6. CONFIGURACIÓN DB Y SAMBA SYNC ---
systemctl start mariadb &>/dev/null
sleep 2
if [ ! -S /run/mysqld/mysqld.sock ]; then
    apt-get install --reinstall -y mariadb-server &>/dev/null
    systemctl start mariadb
fi

# Reset global de privilegios
log_info "Reseteando privilegios de base de datos..."
while read -r U P; do
    mysql -u root -p"$MYSQL_ROOT_PW" -e "REVOKE ALL PRIVILEGES, GRANT OPTION FROM '$U'@'localhost';" 2>/dev/null
    mysql -u root -p"$MYSQL_ROOT_PW" -e "GRANT USAGE ON *.* TO '$U'@'localhost' IDENTIFIED BY '$P';" 2>/dev/null
done <"$FINAL_USER_LIST"

# Sincronización Usuario admindb
log_info "Sincronizando usuario admindb..."
mysql -u root -p"$MYSQL_ROOT_PW" -e "CREATE USER IF NOT EXISTS '$ADMIN_DB_USER'@'localhost' IDENTIFIED BY '$ADMIN_DB_PASS'; GRANT ALL PRIVILEGES ON *.* TO '$ADMIN_DB_USER'@'localhost' WITH GRANT OPTION; FLUSH PRIVILEGES;" &>/dev/null

# Sincronización Usuario phpMyAdmin
log_info "Sincronizando usuario de control de phpMyAdmin..."
mysql -u root -p"$MYSQL_ROOT_PW" -e "
    CREATE USER IF NOT EXISTS 'phpmyadmin'@'localhost' IDENTIFIED BY '$PMA_PASS';
    GRANT ALL PRIVILEGES ON phpmyadmin.* TO 'phpmyadmin'@'localhost';
    FLUSH PRIVILEGES;" &>/dev/null

# Sincronización Samba
log_info "Sincronizando cuentas de Samba..."
while read -r U P; do
    id -u "$U" &>/dev/null || useradd -M -s /usr/sbin/nologin "$U"
    (
        echo "$P"
        echo "$P"
    ) | smbpasswd -a "$U" -s &>/dev/null
done <"$FINAL_USER_LIST"

# --- 7. PROCESAMIENTO DE PROYECTOS ---
echo "# SamaScript SMB Config" >/etc/samba/smb.conf.samascript
rm -f /etc/apache2/sites-enabled/*-p*.conf
echo "# SamaScript Ports" >"$CUSTOM_PORTS"

jq -c '.proyectos[]' "$CONFIG_FILE" | while read -r proj; do
    NAME=$(echo "$proj" | jq -r '.nombre')
    PORT=$(echo "$proj" | jq -r '.puerto')

    echo -e "${YELLOW}----------------------------------------------------"
    echo -e "PROYECTO: $NAME | PUERTO: $PORT${NC}"

    groupadd -f "$NAME"
    mkdir -p "/var/www/$NAME"
    chown root:"$NAME" "/var/www/$NAME"
    chmod 2770 "/var/www/$NAME"

    echo "Listen $PORT" >>"$CUSTOM_PORTS"
    VHOST="/etc/apache2/sites-available/$NAME-p$PORT.conf"
    echo "<VirtualHost *:$PORT>
        DocumentRoot /var/www/$NAME
        ErrorLog \${APACHE_LOG_DIR}/$NAME-error.log
        <Directory /var/www/$NAME>
            Options Indexes FollowSymLinks
            AllowOverride All
            Require all granted
        </Directory>
    </VirtualHost>" >"$VHOST"
    a2ensite "$NAME-p$PORT.conf" &>/dev/null

    mysql -u root -p"$MYSQL_ROOT_PW" -e "CREATE DATABASE IF NOT EXISTS \`$NAME\`;"

    echo "$proj" | jq -c '.desarrolladores[]' | while read -r dev; do
        U=$(echo "$dev" | jq -r '.usuario')
        usermod -aG "$NAME" "$U"
        mysql -u root -p"$MYSQL_ROOT_PW" -e "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE ON \`$NAME\`.* TO '$U'@'localhost';"
        echo -e "  - ${GREEN}$U${NC} vinculado."
    done

    cat >>/etc/samba/smb.conf.samascript <<EOF
[$NAME]
   path = /var/www/$NAME
   browseable = yes
   writable = yes
   valid users = @$NAME, @adminsamas
   force group = $NAME
   create mask = 0660
   directory mask = 0770
   inherit permissions = yes
EOF
done

# --- 8. GESTIÓN DE CONFIGURACIÓN SAMBA (VALIDADA) ---
log_info "Actualizando configuración de Samba..."
SMB_MAIN="/etc/samba/smb.conf"
SMB_BAK="/etc/samba/smb.conf.bak"

# Solo hace backup si el archivo existe y no hay un backup previo
if [ -f "$SMB_MAIN" ] && [ ! -f "$SMB_BAK" ]; then
    cp "$SMB_MAIN" "$SMB_BAK"
    log_success "Backup de Samba creado."
fi

# Generar smb.conf (Si el archivo no existía, se crea de todos modos)
cat >"$SMB_MAIN" <<EOF
[global]
   workgroup = WORKGROUP
   server role = standalone server
   server string = SamaScript Server
   security = user
   map to guest = bad user
   wins support = yes
   log file = /var/log/samba/log.%m

$(cat /etc/samba/smb.conf.samascript)
EOF

# ACLs Administradores
log_info "Actualizando Administradores..."
groupadd -f "adminsamas"
jq -c '.adminsamas[]' $CONFIG_FILE | while read -r admin; do
    U_ADMIN=$(echo "$admin" | jq -r '.usuario')
    P_ADMIN=$(echo "$admin" | jq -r '.password')
    usermod -aG adminsamas "$U_ADMIN"
    setfacl -R -m u:"$U_ADMIN":rwx /var/www
    setfacl -R -d -m u:"$U_ADMIN":rwx /var/www

    # Creamos/Actualizamos el admin con privilegios globales (GRANT ALL PRIVILEGES ON *.*)
    mysql -u root -p"$MYSQL_ROOT_PW" -e "
        CREATE USER IF NOT EXISTS '$U_ADMIN'@'localhost' IDENTIFIED BY '$P_ADMIN';
        ALTER USER '$U_ADMIN'@'localhost' IDENTIFIED BY '$P_ADMIN';
        GRANT ALL PRIVILEGES ON *.* TO '$U_ADMIN'@'localhost' WITH GRANT OPTION;
        FLUSH PRIVILEGES;" &>/dev/null
done

# Permisos Servidor Web
setfacl -m u:www-data:x /var/www
setfacl -R -m u:www-data:rwx /var/www
setfacl -R -d -m u:www-data:rwx /var/www

grep -q "Include custom_ports.conf" /etc/apache2/ports.conf || echo "Include custom_ports.conf" >>/etc/apache2/ports.conf
systemctl restart apache2 smbd mariadb &>/dev/null

# --- 9. RESUMEN DE CREDENCIALES CRÍTICAS ---
echo -e "\n${BLUE}===================================================="
echo -e "       RESUMEN DE ACCESOS MAESTROS (SISTEMA)        "
echo -e "====================================================${NC}"

echo -e "${YELLOW}SERVICIOS CORE:${NC}"
echo -e "  - Root MySQL:      ${RED}$MYSQL_ROOT_PW${NC}"
echo -e "  - phpMyAdmin Pass: ${RED}$PMA_PASS${NC}"
echo -e "  - Admin DB User:   ${GREEN}$ADMIN_DB_USER${NC} (Clave: ${BLUE}$ADMIN_DB_PASS${NC})"

echo -e "\n${YELLOW}ADMINISTRADORES GLOBALES (Samba & Sistema):${NC}"
jq -c '.adminsamas[]' "$CONFIG_FILE" | while read -r admin; do
    U=$(echo "$admin" | jq -r '.usuario')
    P="${PROCESADOS[$U]}"
    echo -e "  - ${GREEN}$U${NC} (Clave: ${BLUE}$P${NC}) [Acceso Total]"
done

echo -e "\n${RED}ALERTAS DE MANTENIMIENTO:${NC}"
for dir in /var/www/*/; do
    [ -d "$dir" ] || continue
    dir_name=$(basename "$dir")
    if [[ "$dir_name" != "html" ]] && ! echo "$GROUP_WHITE_LIST" | grep -qw "$dir_name"; then
        log_warn "Carpeta huérfana (No en JSON): /var/www/$dir_name"
    fi
done

echo -e "${BLUE}====================================================${NC}"
log_success "Sincronización terminada. ¡Sistema blindado!"
rm -f "$TMP_USERS" "$FINAL_USER_LIST"

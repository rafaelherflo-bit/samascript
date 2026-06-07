# SamaScript V7.4 - Enterprise Edition

SamaScript es una solución integral de automatización para servidores de desarrollo Linux. El script se encarga de sincronizar un entorno completo de desarrollo basado en un archivo de configuración JSON, gestionando usuarios, bases de datos, permisos de archivos (ACL), servidores web y servicios de red compartida.

## 🚀 Funcionalidades Principales

### 1. Validación e Integridad
- **Validación de Configuración:** Verifica la existencia y estructura de `/etc/samascript/config.json`.
- **Control de Colisiones:** Evita que existan nombres de proyectos que coincidan con nombres de usuarios, lo cual corrompería la lógica de grupos de Linux.
- **Verificación de Puertos:** Detecta puertos duplicados antes de intentar configurar Apache.
- **Consistencia de Credenciales:** Asegura que un mismo desarrollador no tenga contraseñas diferentes en distintos proyectos.

### 2. Gestión de Seguridad y Usuarios
- **Purga de Sistema (Saneamiento):** Elimina automáticamente usuarios y grupos del sistema (UID >= 1000) que no estén declarados en el archivo de configuración o en la lista de mantenimiento.
- **Mapeo de Usuarios:** Sincroniza usuarios administradores y desarrolladores entre el sistema Linux, Samba y MariaDB.
- **Usuarios Prohibidos:** Bloquea el uso de nombres reservados como `root`, `www-data`, `mysql`, etc.

### 3. Automatización de Servidor Web (Apache)
- **VirtualHosts Dinámicos:** Crea automáticamente un archivo de configuración por cada proyecto basándose en su puerto asignado.
- **Gestión de Puertos:** Centraliza los puertos en `/etc/apache2/custom_ports.conf`.
- **Limpieza:** Desactiva los sitios por defecto (000-default) para evitar conflictos.

### 4. Automatización de Bases de Datos (MariaDB/MySQL)
- **Bases de Datos por Proyecto:** Crea una base de datos independiente para cada proyecto.
- **Permisos Granulares:** Asigna permisos de `SELECT, INSERT, UPDATE, DELETE, CREATE` a los desarrolladores solo en sus bases de datos correspondientes.
- **Administración Global:** Configura usuarios maestros (`admindb`, `adminsamas`) y el usuario de control para phpMyAdmin.

### 5. Compartición de Archivos (Samba)
- **Sincronización SMB:** Genera automáticamente recursos compartidos en Samba para cada proyecto.
- **Acceso Restringido:** Solo los desarrolladores asignados al proyecto y los administradores pueden acceder a las carpetas vía red.
- **Máscaras de Creación:** Fuerza permisos `0660` para archivos y `0770` para directorios para asegurar la colaboración.

### 6. Sistema de Permisos Avanzado (ACL)
- Implementa **Linux Access Control Lists (ACL)** para permitir que tanto el servidor web (`www-data`) como los usuarios administradores tengan acceso total de lectura/escritura en `/var/www/` de forma recursiva y hereditaria.

## 🛠️ Requisitos

- Sistema operativo basado en Debian/Ubuntu.
- Ejecución con privilegios de **root** (sudo).
- Archivo de configuración en: `/etc/samascript/config.json`.

## 📋 Estructura del JSON (Resumen)

El script espera una estructura similar a esta:
```json
{
  "mysql_root_password": "...",
  "pma_db_pass": "...",
  "admin_db_pass": "...",
  "adminsamas": [
    { "usuario": "admin1", "password": "..." }
  ],
  "proyectos": [
    {
      "nombre": "proyecto_alpha",
      "puerto": 8081,
      "desarrolladores": [
        { "usuario": "dev1", "password": "..." }
      ]
    }
  ],
  "mantener_usuarios": ["usuario_especial"]
}
```

## 📂 Logs y Auditoría

- **Log del Script:** `/var/log/samascript.log`
- **Configuración de Puertos:** `/etc/apache2/custom_ports.conf`
- **Configuración Samba:** `/etc/samba/smb.conf.samascript`

---
**Advertencia:** Este script realiza operaciones destructivas (limpieza de usuarios y grupos no declarados). Se recomienda su uso en servidores dedicados a desarrollo.
```

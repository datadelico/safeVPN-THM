# SafeVPN-THM

Script mejorado para gestionar conexiones VPN de forma segura, específicamente optimizado para TryHackMe.

## Características

- Gestión automática de reglas iptables para asegurar la conexión
- Manejo de errores mejorado
- Tiempo de espera configurable para la interfaz VPN
- Backup y restauración de reglas de firewall
- Cierre limpio de conexiones
- Soporte para múltiples rutas VPN

## Requisitos

- OpenVPN instalado
- Permisos de administrador (sudo)
- Archivo de configuración OpenVPN (.ovpn)

## Uso

```bash
sudo ./safevpn.sh <archivo_config.ovpn> [servidor_vpn]
```

Ejemplo:
```bash
sudo ./safevpn.sh file.ovpn 10.10.10.10
```

## Solución de problemas

Si experimentas problemas con la interfaz VPN:

1. Edita el script y aumenta el valor de `VPN_TIMEOUT` (por defecto 60 segundos)
2. Verifica que tu archivo de configuración OpenVPN esté correcto
3. Comprueba los logs en `./backups/safevpn-thm.log` para obtener más detalles
4. Utiliza el script auxiliar `helpers/network-check.sh` para diagnosticar problemas de rutas de red

### Problemas comunes

- **Error con iptables y múltiples redes**: Si ves errores relacionados con `host/network not found`, esto puede indicar un problema con la configuración de rutas de red. El script actualizado maneja este caso procesando cada ruta individualmente.

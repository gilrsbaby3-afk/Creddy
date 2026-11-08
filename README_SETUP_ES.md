# Configurar la app Creddy (piloto manual)

Esta versión registra clientes con correo/contraseña, guarda nombre, cédula y teléfono, permite pedir revisión de crédito, solicitar una recarga procesada manualmente y reportar pagos. La aprobación y confirmación de pagos están protegidas por funciones SQL y el rol administrador de Supabase. No se conecta a una operadora ni ejecuta recargas automáticamente.

## Antes de usar

- Haz estas pruebas primero con cuentas ficticias, sin dinero ni datos reales. Confirma con tu asesor local los requisitos legales y de privacidad para manejar datos de identificación y crédito.
- No publiques la app ni la uses para clientes hasta validar el flujo completo y la configuración del proyecto.
- Nunca pongas una `secret`/`service_role` key en el navegador. El frontend solo usa Project URL y la clave pública (`publishable` o `anon`).

## Supabase

1. Abre el proyecto correcto → **SQL Editor** → crea una consulta nueva.
2. Copia el contenido completo de `supabase_schema.sql` de este repositorio y ejecútalo una vez. Crea tablas nuevas `app_profiles`, `credit_requests`, `credit_accounts`, `recharge_orders` y `payment_reports`; no borra las tablas antiguas.
3. En **Authentication → Sign In / Providers**, deja Email habilitado y los registros permitidos. Se recomienda mantener la confirmación de correo encendida. Configura **URL Configuration** con la URL de prueba de tu app y los redirect URLs que realmente uses.
4. En **Project Settings → API Keys**, copia **Project URL** y **Publishable key** (o `anon` key legacy). En `index.html`, reemplaza `https://TU_PROYECTO.supabase.co` y `TU_PUBLISHABLE_O_ANON_KEY`. No compartas la secret/service_role key.
5. Crea tu cuenta de administrador con el formulario de la app y confirma el correo. Después, en Supabase → **SQL Editor**, sustituye el correo por el tuyo y ejecuta:

   ```sql
   update public.app_profiles p
   set is_admin = true
   from auth.users u
   where p.id = u.id and lower(u.email) = lower('TU_CORREO_ADMIN');
   ```

   Verifica que solo tu usuario queda con `is_admin = true`. No permitas que clientes usen ese correo.

## Prueba antes de clientes

1. Crea una cuenta cliente ficticia; confirma correo e inicia sesión.
2. Envía una solicitud de crédito. Entra con la cuenta admin y apruébala con una tasa BCV correcta.
3. Con la cuenta cliente, solicita una recarga menor o igual al saldo disponible. La solicitud resta saldo disponible y registra la deuda; debes hacer la recarga fuera de la app y después marcarla completada.
4. Reporta un pago ficticio. Con la cuenta admin confirma el pago solo después de verificarlo; la deuda se actualizará.
5. Prueba también rechazar solicitud, recarga y pago, y revisa que cliente A nunca vea los datos de cliente B.

La clave administrativa es el campo `is_admin` en `app_profiles`; solo un administrador de Supabase debe cambiarlo. El botón de administración aparece solo para admins autorizados y el servidor vuelve a verificar el rol en cada operación.

# Logica de negocio - PickDriver API (Vapor)

Este documento resume las reglas reales implementadas en la API para ligas, draft, picks, equipos y standings.

## Convenciones generales
- JSON: camelCase por defecto; algunos endpoints usan snake_case en payloads y query params.
- Todas las rutas de ligas/draft/picks requieren JWT (Authorization: Bearer).
- Las validaciones se aplican en runtime; no hay reglas adicionales fuera del codigo.

## Ligas
### Creacion
- Requiere temporada activa (season.active = true). Si no, devuelve 400.
- La liga se crea con status "pending".
- El creador queda como owner y tambien se agrega como miembro.
- `teamsEnabled`, `bansEnabled`, `mirrorEnabled` se aceptan sin validaciones adicionales al crear.
- `maxPlayers` define el limite de miembros.

### Unirse a una liga
- Solo se puede unir si la liga esta en "pending".
- No permite unirse si ya es miembro.
- No permite unirse si la liga esta llena (memberCount >= maxPlayers).

### Permisos
- `owner` (creador) es el unico que puede:
  - asignar orden de picks (`assign-pick-order`)
  - iniciar el draft (`start-draft`)
  - eliminar la liga (solo si esta "pending")
- Varias operaciones requieren ser miembro de la liga (ver endpoints protegidos).

### Eliminar liga
- Solo owner.
- Solo si la liga esta en "pending".
- La eliminacion hace cascade a miembros, equipos, drafts, picks y autopicks por FK.

## Equipos (teams)
### Reglas de habilitacion
- Solo aplican si `teamsEnabled = true`.
- La liga debe estar en "pending".
- La liga debe estar completa (memberCount == maxPlayers).

### Reglas de tamanos
- Tamano minimo por equipo: 2.
- Maximo de equipos = min(totalPlayers / 2, cantidad de equipos F1 en la temporada).
- La distribucion debe ser factible y balanceada:
  - cada equipo debe quedar entre floor(totalPlayers / k) y ceil(totalPlayers / k)
  - no se permiten equipos por debajo del minimo

### Reglas de membresia
- No se permiten usuarios duplicados dentro de un mismo equipo.
- Un usuario no puede estar en multiples equipos.
- Solo miembros de la liga pueden estar en equipos.

## Drafts
### Activacion (start-draft)
- Solo owner.
- Liga debe estar en "pending".
- La liga debe estar completa (members == maxPlayers).
- Si `teamsEnabled = true`, todos los jugadores deben estar asignados a equipos.

### Orden de picks
- Si existe `pickOrder` asignado para todos los miembros, se respeta.
- Si no, se calcula un orden aleatorio:
  - sin equipos: shuffle directo
  - con equipos: shuffle por equipo y round-robin entre equipos
- Por cada carrera futura desde `initialRaceRound`, se rota el orden.
- Si `mirrorEnabled = true`, el orden se duplica en espejo (rotated + reversed).

### Deadlines
- `firstHalfDeadline = fp1Time - 36h`
- `secondHalfDeadline = fp1Time`
- Si no hay `fp1Time` o no existe draft para la carrera, devuelve 404.

## Autopick
- Cada usuario puede guardar una lista ordenada de drivers (`driverIDs`) por liga.
- Se eliminan duplicados manteniendo orden.
- La lista debe coincidir con drivers de la temporada de la liga.
- Si se envia lista vacia, se borra la configuracion.
- Cuando expira un turno, se intenta autopick con el primer driver disponible:
  - no baneado por el usuario
  - no pickeado por otro jugador
- Si no hay autopick valido, el turno se considera expirado y se avanza igual.

## Picks
### Reglas de acceso
- Solo el usuario del turno puede pickear.
- Si `teamsEnabled = true` y falta menos de 1h para fp1, un companero puede pickear por el turno actual.

### Validaciones
- No se permite pick/ban si la carrera ya comenzo o esta completada:
  - `race.completed == true` o `race.raceTime < now`
- El driver debe existir y pertenecer a la temporada de la carrera.
- No se permite pickear un driver ya pickeado (global en el draft).
- No se permite pickear un driver que el usuario tenga baneado.
- Solo un pick por usuario y por "mirror slot" (`is_mirror_pick`).

### Efectos
- Inserta pick y avanza `currentPickIndex`.
- Notifica al siguiente jugador cuando corresponde.

## Bans
### Reglas de acceso
- Solo si `bansEnabled = true`.
- Solo se puede banear el pick inmediatamente anterior.
- No se puede banear al ultimo jugador del orden (salvo que tambien sea el primero).
- No se permite banear la misma persona mas de una vez por el mismo banner.
- Permisos:
  - sin equipos: solo el usuario del turno
  - con equipos: el usuario del turno o un companero

### Cantidad de bans
- Sin equipos: 2 bans por usuario.
- Con equipos: 3 bans por equipo.

### Efectos
- Marca el pick como baneado (`is_banned = true`) y guarda `banned_by`.
- Retrocede `currentPickIndex` al pick anterior para que el usuario re-pickee.
- Notifica al siguiente jugador despues del cambio.

## Standings y puntuacion
- Solo se consideran picks no baneados.
- Picks hechos por autopick valen 50% de los puntos del driver.
- Los standings se calculan sobre carreras completadas.
- En picks con mirror, el sistema calcula la posicion considerando el orden espejo.

## Notificaciones relacionadas al draft
- Al iniciar draft se notifica al primer usuario del orden.
- Al completar un pick se notifica al siguiente usuario.
- Al publicar resultados se generan notificaciones asociadas a la carrera.


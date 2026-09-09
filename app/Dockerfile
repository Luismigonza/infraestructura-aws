# ===========================================================================
# Imagen de la aplicacion de ejemplo
# ===========================================================================

# Version fijada, no `node:latest`. Una imagen base que cambia sola convierte
# un despliegue reproducible en una loteria.
#
# La variante `alpine` pesa ~50 MB frente a ~400 MB de la completa. Menos peso
# es menos superficie de ataque, menos que descargar en cada despliegue y menos
# trafico saliendo por el NAT Gateway (que se cobra por GB).
FROM node:22-alpine

# Las imagenes de Node traen ya un usuario sin privilegios llamado `node`.
WORKDIR /app

# Copiar primero package.json y despues el codigo NO es un capricho de estilo:
# Docker cachea cada capa. Mientras las dependencias no cambien, reconstruir
# tras editar server.js reutiliza la capa de `npm install` y tarda segundos en
# vez de minutos.
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

COPY server.js ./

# Ejecutar como root dentro del contenedor es un riesgo innecesario: si alguien
# encuentra un fallo en la aplicacion, hereda los privilegios del proceso.
USER node

ENV NODE_ENV=production
ENV PORT=8080
EXPOSE 8080

CMD ["node", "server.js"]

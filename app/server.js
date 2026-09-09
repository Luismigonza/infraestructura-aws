// ===========================================================================
// APLICACION DE EJEMPLO
// ===========================================================================
// Una API mínima cuyo único trabajo es demostrar que la infraestructura
// funciona de punta a punta: que el balanceador la alcanza, y que ella alcanza
// la base de datos.
//
// Sin framework a propósito. Node trae un servidor HTTP en la biblioteca
// estándar, y la única dependencia real es el driver de PostgreSQL. Menos
// dependencias, menos superficie que parchear y una imagen más pequeña.
// ===========================================================================

const http = require("node:http");
const { Pool } = require("pg");

const PORT = Number(process.env.PORT || 8080);

// El pool se crea al arrancar, pero NO se conecta hasta la primera consulta.
// Es importante: si el contenedor exigiera la base de datos para arrancar, un
// problema pasajero de red impediría que el servicio levantara siquiera, y
// nunca llegaríamos a ver el error en el endpoint de diagnóstico.
const pool = new Pool({
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT || 5432),
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,

  // RDS obliga a TLS. El certificado lo firma una CA propia de AWS que no está
  // en el almacén por defecto de Node, así que se acepta sin verificar la
  // cadena. El tráfico va cifrado igualmente, y nunca sale de subnets privadas
  // a las que no llega nadie desde internet.
  ssl: { rejectUnauthorized: false },

  // Si la base de datos no responde, falla rápido en vez de dejar la petición
  // colgada hasta que el balanceador la corte por tiempo.
  connectionTimeoutMillis: 5000,
  max: 5,
});

const json = (res, code, body) => {
  const payload = JSON.stringify(body, null, 2);
  res.writeHead(code, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
};

const rutas = {
  // -------------------------------------------------------------------------
  // Health check del balanceador.
  //
  // DELIBERADAMENTE no toca la base de datos. Si lo hiciera, una caída de RDS
  // haría que el ALB marcara las tareas como muertas y las reemplazara en
  // bucle, convirtiendo un problema de base de datos en una caída total del
  // servicio. El health check responde "¿este proceso está vivo?", no
  // "¿está todo el sistema perfecto?".
  // -------------------------------------------------------------------------
  "/health": async (_req, res) => json(res, 200, { status: "ok" }),

  "/": async (_req, res) =>
    json(res, 200, {
      servicio: "infra-aws-demo",
      mensaje: "Desplegado en ECS Fargate detrás de un Application Load Balancer.",
      endpoints: {
        "/health": "sonda del balanceador, no toca la base de datos",
        "/db": "comprueba la conexión con PostgreSQL",
      },
    }),

  // -------------------------------------------------------------------------
  // La prueba de fuego: demuestra que la tarea, en una subnet privada, alcanza
  // a RDS, en otra subnet privada, usando una contraseña que nadie escribió a
  // mano en ninguna parte.
  // -------------------------------------------------------------------------
  "/db": async (_req, res) => {
    try {
      const { rows } = await pool.query(
        "SELECT version() AS version, current_database() AS base, now() AS momento"
      );
      json(res, 200, { conectado: true, ...rows[0] });
    } catch (err) {
      json(res, 503, { conectado: false, error: err.message });
    }
  },
};

const server = http.createServer(async (req, res) => {
  const ruta = new URL(req.url, `http://${req.headers.host}`).pathname;
  const manejador = rutas[ruta];

  if (!manejador) return json(res, 404, { error: "no encontrado", ruta });

  try {
    await manejador(req, res);
  } catch (err) {
    json(res, 500, { error: err.message });
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`escuchando en 0.0.0.0:${PORT}`);
});

// ECS envía SIGTERM cuando va a detener una tarea (un despliegue nuevo, un
// escalado hacia abajo). Cerrar ordenadamente hace que las peticiones en curso
// terminen en vez de cortarse a mitad.
const apagar = () => {
  console.log("SIGTERM recibido, cerrando");
  server.close(() => pool.end().finally(() => process.exit(0)));
};
process.on("SIGTERM", apagar);
process.on("SIGINT", apagar);

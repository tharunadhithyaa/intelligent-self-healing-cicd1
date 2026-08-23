import { Request, Response, NextFunction } from "express";
import client from "prom-client";
import mongoose from "mongoose";

// Create a custom registry
export const register = new client.Registry();

// Enable collection of default Node.js process & OS metrics
client.collectDefaultMetrics({
  register,
  prefix: "civicpulse_",
});

// Custom HTTP Request Counter
export const httpRequestCounter = new client.Counter({
  name: "civicpulse_http_requests_total",
  help: "Total number of HTTP requests processed by CivicPulse backend",
  labelNames: ["method", "route", "status"],
  registers: [register],
});

// Custom HTTP Duration Histogram
export const httpRequestDuration = new client.Histogram({
  name: "civicpulse_http_request_duration_seconds",
  help: "HTTP request duration in seconds for CivicPulse backend",
  labelNames: ["method", "route", "status"],
  buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
  registers: [register],
});

// Custom HTTP Error Counter
export const httpErrorCounter = new client.Counter({
  name: "civicpulse_http_errors_total",
  help: "Total number of HTTP 4xx and 5xx errors in CivicPulse backend",
  labelNames: ["method", "route", "status"],
  registers: [register],
});

// Active Requests Gauge
export const activeRequestsGauge = new client.Gauge({
  name: "civicpulse_http_active_requests",
  help: "Number of active HTTP requests currently being handled",
  labelNames: ["method"],
  registers: [register],
});

// Database Connection Status Gauge
export const dbStatusGauge = new client.Gauge({
  name: "civicpulse_db_status",
  help: "MongoDB connection status (1 = connected, 0 = disconnected)",
  registers: [register],
});

// Helper to normalize Express route paths (preventing high cardinality from IDs)
function getNormalizedRoute(req: Request): string {
  if (req.route?.path) {
    const baseUrl = req.baseUrl || "";
    const routePath = req.route.path;
    return `${baseUrl}${routePath === "/" ? "" : routePath}`;
  }
  const urlPath = req.path || "/";
  return urlPath.replace(/\/[a-f0-9]{24}/gi, "/:id").replace(/\/\d+/g, "/:id");
}

// Middleware to track request metrics
export function metricsMiddleware(req: Request, res: Response, next: NextFunction): void {
  if (req.path === "/metrics" || req.path === "/api/metrics") {
    next();
    return;
  }

  const method = req.method;
  activeRequestsGauge.inc({ method });

  const startTime = process.hrtime();

  res.on("finish", () => {
    activeRequestsGauge.dec({ method });

    const diff = process.hrtime(startTime);
    const durationSeconds = diff[0] + diff[1] / 1e9;
    const route = getNormalizedRoute(req);
    const status = res.statusCode.toString();

    httpRequestCounter.inc({ method, route, status });
    httpRequestDuration.observe({ method, route, status }, durationSeconds);

    if (res.statusCode >= 400) {
      httpErrorCounter.inc({ method, route, status });
    }

    const dbState = mongoose.connection.readyState;
    dbStatusGauge.set(dbState === 1 ? 1 : 0);
  });

  next();
}

// Handler for /metrics endpoint
export async function metricsHandler(_req: Request, res: Response): Promise<void> {
  try {
    const dbState = mongoose.connection.readyState;
    dbStatusGauge.set(dbState === 1 ? 1 : 0);

    res.set("Content-Type", register.contentType);
    const metricsData = await register.metrics();
    res.end(metricsData);
  } catch (error) {
    res.status(500).end((error as Error).message);
  }
}

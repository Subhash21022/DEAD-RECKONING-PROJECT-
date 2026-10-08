import axios, { AxiosInstance, AxiosRequestConfig, AxiosResponse } from "axios";

const BASE_URL = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8000";

const client: AxiosInstance = axios.create({
  baseURL: BASE_URL,
  timeout: 15000,
  headers: { "Content-Type": "application/json" },
});

client.interceptors.request.use((config) => {
  if (typeof window !== "undefined") {
    const token = localStorage.getItem("auth_token");
    if (token) {
      config.headers.Authorization = `Bearer ${token}`;
    }
  }
  return config;
});

client.interceptors.response.use(
  (res) => res,
  (error) => {
    if (error.response?.status === 401 && typeof window !== "undefined") {
      localStorage.removeItem("auth_token");
      window.location.href = "/login";
    }
    return Promise.reject(error);
  }
);

async function get<T>(url: string, config?: AxiosRequestConfig): Promise<T> {
  const res: AxiosResponse<T> = await client.get(url, config);
  return res.data;
}

async function post<T>(
  url: string,
  data?: unknown,
  config?: AxiosRequestConfig
): Promise<T> {
  const res: AxiosResponse<T> = await client.post(url, data, config);
  return res.data;
}

async function patch<T>(
  url: string,
  data?: unknown,
  config?: AxiosRequestConfig
): Promise<T> {
  const res: AxiosResponse<T> = await client.patch(url, data, config);
  return res.data;
}

async function del<T>(url: string, config?: AxiosRequestConfig): Promise<T> {
  const res: AxiosResponse<T> = await client.delete(url, config);
  return res.data;
}

export interface Ranger {
  id: string;
  callsign: string;
  lat: number;
  lon: number;
  heading_deg: number;
  speed_kmh: number;
  mode: string;
  gnss_quality: string;
  confidence_radius_m: number;
  battery_pct: number;
  is_sos: boolean;
  last_update: string;
}

export interface Patrol {
  id: string;
  ranger_id: string;
  ranger_callsign: string;
  start_time: string;
  end_time: string | null;
  status: string;
  distance_km: number;
  coverage_km2: number;
  breadcrumb_count: number;
}

export interface Breadcrumb {
  timestamp_s: number;
  lat: number;
  lon: number;
  speed_kmh: number;
  heading_deg: number;
  mode: string;
  confidence_m: number;
  is_outage: boolean;
}

export interface Alert {
  id: string;
  ranger_id: string;
  ranger_callsign: string;
  alert_type: "SOS" | "DEAD_RANGER" | "GEOFENCE_BREACH";
  severity: "CRITICAL" | "HIGH" | "MEDIUM" | "LOW";
  message: string;
  lat: number;
  lon: number;
  created_at: string;
  resolved_at: string | null;
  is_resolved: boolean;
}

export interface GeoFenceZone {
  id: string;
  name: string;
  zone_type: "CORE_PROTECTED" | "BUFFER_ZONE" | "POACHING_RISK";
  polygon: { type: "Polygon"; coordinates: number[][][] };
}

export interface DashboardStats {
  active_rangers: number;
  active_patrols: number;
  total_coverage_km2: number;
  active_alerts: number;
  recent_alerts: Alert[];
  recent_patrols: Patrol[];
}

export const api = {
  getDashboard: () => get<DashboardStats>("/api/v1/patrol/dashboard"),
  getRangers: () => get<Ranger[]>("/api/v1/telemetry/rangers"),
  getPatrols: () => get<Patrol[]>("/api/v1/patrol/list"),
  getPatrolBreadcrumbs: (patrolId: string) =>
    get<Breadcrumb[]>(`/api/v1/patrol/${patrolId}/breadcrumbs`),
  getAlerts: (resolved?: boolean) =>
    get<Alert[]>("/api/v1/alerts/list", {
      params: resolved !== undefined ? { resolved } : {},
    }),
  resolveAlert: (alertId: string) =>
    patch<Alert>(`/api/v1/alerts/${alertId}/resolve`),
  getGeoFences: () => get<GeoFenceZone[]>("/api/v1/geofence/list"),
};

export default api;

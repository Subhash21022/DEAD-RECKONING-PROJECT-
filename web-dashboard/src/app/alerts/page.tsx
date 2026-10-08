"use client";

import { useState, useEffect, useCallback } from "react";
import { format } from "date-fns";
import SOSBanner from "@/components/telemetry/SOSBanner";
import { useWebSocket } from "@/lib/websocket";
import api, { Alert } from "@/lib/api";

const SEVERITY_COLORS: Record<string, string> = {
  CRITICAL: "bg-red-500/20 text-red-400 ring-1 ring-red-500/30",
  HIGH: "bg-orange-500/20 text-orange-400 ring-1 ring-orange-500/30",
  MEDIUM: "bg-yellow-500/20 text-yellow-400 ring-1 ring-yellow-500/30",
  LOW: "bg-blue-500/20 text-blue-400 ring-1 ring-blue-500/30",
};

const TYPE_LABELS: Record<string, string> = {
  SOS: "SOS Emergency",
  DEAD_RANGER: "Dead Ranger",
  GEOFENCE_BREACH: "GeoFence Breach",
};

type FilterType = "ALL" | "SOS" | "DEAD_RANGER" | "GEOFENCE_BREACH";
type FilterStatus = "ALL" | "ACTIVE" | "RESOLVED";

export default function AlertsPage() {
  const [alerts, setAlerts] = useState<Alert[]>([]);
  const [filterType, setFilterType] = useState<FilterType>("ALL");
  const [filterStatus, setFilterStatus] = useState<FilterStatus>("ALL");
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    api
      .getAlerts()
      .then(setAlerts)
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  const handleMessage = useCallback((data: unknown) => {
    const msg = data as { type: string; payload: Alert };
    if (msg.type === "alert") {
      const a = msg.payload;
      setAlerts((prev) => {
        const idx = prev.findIndex((x) => x.id === a.id);
        if (idx >= 0) {
          const copy = [...prev];
          copy[idx] = a;
          return copy;
        }
        return [a, ...prev];
      });
    }
  }, []);

  useWebSocket({
    url: "/ws/alerts",
    onMessage: handleMessage,
  });

  const handleResolve = useCallback(async (alertId: string) => {
    try {
      await api.resolveAlert(alertId);
      setAlerts((prev) =>
        prev.map((a) =>
          a.id === alertId
            ? { ...a, is_resolved: true, resolved_at: new Date().toISOString() }
            : a
        )
      );
    } catch {
      /* offline */
    }
  }, []);

  const filtered = alerts.filter((a) => {
    if (filterType !== "ALL" && a.alert_type !== filterType) return false;
    if (filterStatus === "ACTIVE" && a.is_resolved) return false;
    if (filterStatus === "RESOLVED" && !a.is_resolved) return false;
    return true;
  });

  return (
    <div className="flex h-full flex-col">
      <SOSBanner
        alerts={alerts}
        onViewMap={() => {
          window.location.href = "/live-tracking";
        }}
        onAcknowledge={handleResolve}
      />

      <div className="border-b border-tactical-800 bg-tactical-950 px-6 py-4">
        <h2 className="text-lg font-bold text-tactical-100">Alert Command Log</h2>
        <p className="text-xs text-tactical-500">
          SOS, Dead Ranger, and GeoFence breach incidents
        </p>
      </div>

      <div className="border-b border-tactical-800 px-6 py-3">
        <div className="flex items-center gap-4">
          <div className="flex gap-1">
            {(["ALL", "SOS", "DEAD_RANGER", "GEOFENCE_BREACH"] as FilterType[]).map(
              (t) => (
                <button
                  key={t}
                  onClick={() => setFilterType(t)}
                  className={`rounded-md px-3 py-1 text-xs font-medium transition-colors ${
                    filterType === t
                      ? "bg-forest-600 text-white"
                      : "bg-tactical-800 text-tactical-400 hover:text-tactical-200"
                  }`}
                >
                  {t === "ALL" ? "All Types" : TYPE_LABELS[t] || t}
                </button>
              )
            )}
          </div>
          <div className="h-4 w-px bg-tactical-700" />
          <div className="flex gap-1">
            {(["ALL", "ACTIVE", "RESOLVED"] as FilterStatus[]).map((s) => (
              <button
                key={s}
                onClick={() => setFilterStatus(s)}
                className={`rounded-md px-3 py-1 text-xs font-medium transition-colors ${
                  filterStatus === s
                    ? "bg-forest-600 text-white"
                    : "bg-tactical-800 text-tactical-400 hover:text-tactical-200"
                }`}
              >
                {s === "ALL" ? "All" : s.charAt(0) + s.slice(1).toLowerCase()}
              </button>
            ))}
          </div>
          <div className="ml-auto text-xs text-tactical-500">
            {filtered.length} alert{filtered.length !== 1 ? "s" : ""}
          </div>
        </div>
      </div>

      <div className="flex-1 overflow-y-auto">
        {loading ? (
          <div className="flex items-center justify-center py-16">
            <div className="h-6 w-6 animate-spin rounded-full border-2 border-forest-500 border-t-transparent" />
          </div>
        ) : filtered.length === 0 ? (
          <div className="py-16 text-center text-sm text-tactical-600">
            No alerts match the current filters
          </div>
        ) : (
          <table className="w-full text-left">
            <thead className="sticky top-0 bg-tactical-950">
              <tr className="border-b border-tactical-800">
                <th className="px-6 py-2.5 text-[10px] font-semibold uppercase tracking-wider text-tactical-500">
                  Severity
                </th>
                <th className="px-4 py-2.5 text-[10px] font-semibold uppercase tracking-wider text-tactical-500">
                  Type
                </th>
                <th className="px-4 py-2.5 text-[10px] font-semibold uppercase tracking-wider text-tactical-500">
                  Ranger
                </th>
                <th className="px-4 py-2.5 text-[10px] font-semibold uppercase tracking-wider text-tactical-500">
                  Message
                </th>
                <th className="px-4 py-2.5 text-[10px] font-semibold uppercase tracking-wider text-tactical-500">
                  Location
                </th>
                <th className="px-4 py-2.5 text-[10px] font-semibold uppercase tracking-wider text-tactical-500">
                  Time
                </th>
                <th className="px-4 py-2.5 text-[10px] font-semibold uppercase tracking-wider text-tactical-500">
                  Status
                </th>
                <th className="px-4 py-2.5" />
              </tr>
            </thead>
            <tbody>
              {filtered.map((alert) => (
                <tr
                  key={alert.id}
                  className={`border-b border-tactical-800/30 transition-colors hover:bg-tactical-900/50 ${
                    alert.alert_type === "SOS" && !alert.is_resolved
                      ? "bg-red-950/10"
                      : ""
                  }`}
                >
                  <td className="px-6 py-3">
                    <span
                      className={`badge ${SEVERITY_COLORS[alert.severity] || ""}`}
                    >
                      {alert.severity}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-xs font-medium text-tactical-200">
                    {TYPE_LABELS[alert.alert_type] || alert.alert_type}
                  </td>
                  <td className="px-4 py-3 text-xs font-semibold text-tactical-100">
                    {alert.ranger_callsign}
                  </td>
                  <td className="max-w-xs truncate px-4 py-3 text-xs text-tactical-400">
                    {alert.message}
                  </td>
                  <td className="px-4 py-3 font-mono text-[10px] text-tactical-500">
                    {alert.lat.toFixed(5)}, {alert.lon.toFixed(5)}
                  </td>
                  <td className="px-4 py-3 text-xs text-tactical-400">
                    {format(new Date(alert.created_at), "dd MMM HH:mm:ss")}
                  </td>
                  <td className="px-4 py-3">
                    {alert.is_resolved ? (
                      <span className="badge bg-tactical-700/50 text-tactical-400">
                        Resolved
                      </span>
                    ) : (
                      <span className="badge bg-red-900/40 text-red-400 ring-1 ring-red-500/20">
                        Active
                      </span>
                    )}
                  </td>
                  <td className="px-4 py-3">
                    {!alert.is_resolved && (
                      <button
                        onClick={() => handleResolve(alert.id)}
                        className="rounded-md bg-tactical-800 px-2.5 py-1 text-[10px] font-medium text-tactical-300 transition-colors hover:bg-tactical-700 hover:text-tactical-100"
                      >
                        Resolve
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}

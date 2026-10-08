"use client";

import { useEffect, useState, useCallback } from "react";
import { format } from "date-fns";
import api, { DashboardStats, Alert } from "@/lib/api";

function StatCard({
  label,
  value,
  unit,
  color,
}: {
  label: string;
  value: number | string;
  unit?: string;
  color: string;
}) {
  const colorMap: Record<string, string> = {
    green: "text-forest-400 bg-forest-950/50 border-forest-700/40",
    blue: "text-blue-400 bg-blue-950/50 border-blue-700/40",
    amber: "text-amber-400 bg-amber-950/50 border-amber-700/40",
    red: "text-red-400 bg-red-950/50 border-red-700/40",
  };

  return (
    <div
      className={`rounded-xl border p-5 backdrop-blur-sm ${colorMap[color] || colorMap.green}`}
    >
      <p className="text-xs font-medium uppercase tracking-wider text-tactical-400">
        {label}
      </p>
      <p className="mt-2 text-3xl font-bold tabular-nums">
        {value}
        {unit && (
          <span className="ml-1 text-sm font-normal text-tactical-500">
            {unit}
          </span>
        )}
      </p>
    </div>
  );
}

const SEVERITY_COLORS: Record<string, string> = {
  CRITICAL: "bg-red-500/20 text-red-400 ring-1 ring-red-500/30",
  HIGH: "bg-orange-500/20 text-orange-400 ring-1 ring-orange-500/30",
  MEDIUM: "bg-yellow-500/20 text-yellow-400 ring-1 ring-yellow-500/30",
  LOW: "bg-blue-500/20 text-blue-400 ring-1 ring-blue-500/30",
};

function AlertRow({ alert }: { alert: Alert }) {
  return (
    <tr className="border-b border-tactical-800/50 transition-colors hover:bg-tactical-900/50">
      <td className="px-4 py-3">
        <span
          className={`badge ${SEVERITY_COLORS[alert.severity] || ""}`}
        >
          {alert.severity}
        </span>
      </td>
      <td className="px-4 py-3 text-sm font-medium text-tactical-200">
        {alert.alert_type.replace("_", " ")}
      </td>
      <td className="px-4 py-3 text-sm text-tactical-300">
        {alert.ranger_callsign}
      </td>
      <td className="px-4 py-3 text-sm text-tactical-400">
        {alert.message}
      </td>
      <td className="px-4 py-3 text-xs text-tactical-500">
        {format(new Date(alert.created_at), "HH:mm:ss")}
      </td>
    </tr>
  );
}

export default function OverviewPage() {
  const [stats, setStats] = useState<DashboardStats | null>(null);
  const [loading, setLoading] = useState(true);

  const fetchData = useCallback(async () => {
    try {
      const data = await api.getDashboard();
      setStats(data);
    } catch {
      /* offline or server unavailable — keep stale data */
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 30000);
    return () => clearInterval(interval);
  }, [fetchData]);

  if (loading && !stats) {
    return (
      <div className="flex h-full items-center justify-center">
        <div className="h-8 w-8 animate-spin rounded-full border-2 border-forest-500 border-t-transparent" />
      </div>
    );
  }

  const data = stats || {
    active_rangers: 0,
    active_patrols: 0,
    total_coverage_km2: 0,
    active_alerts: 0,
    recent_alerts: [],
    recent_patrols: [],
  };

  return (
    <div className="p-6">
      <div className="mb-6">
        <h2 className="text-xl font-bold text-tactical-100">
          Mission Overview
        </h2>
        <p className="text-sm text-tactical-400">
          Real-time sanctuary patrol intelligence
        </p>
      </div>

      <div className="mb-8 grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard
          label="Active Rangers"
          value={data.active_rangers}
          color="green"
        />
        <StatCard
          label="Active Patrols"
          value={data.active_patrols}
          color="blue"
        />
        <StatCard
          label="Coverage"
          value={data.total_coverage_km2.toFixed(2)}
          unit="km2"
          color="amber"
        />
        <StatCard
          label="Active Alerts"
          value={data.active_alerts}
          color={data.active_alerts > 0 ? "red" : "green"}
        />
      </div>

      <div className="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <div className="rounded-xl border border-tactical-700/50 bg-tactical-900/60">
          <div className="border-b border-tactical-800 px-5 py-3">
            <h3 className="text-sm font-semibold text-tactical-200">
              Recent Alerts
            </h3>
          </div>
          {data.recent_alerts.length === 0 ? (
            <div className="px-5 py-8 text-center text-sm text-tactical-500">
              No active alerts
            </div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-left">
                <thead>
                  <tr className="border-b border-tactical-800">
                    <th className="px-4 py-2 text-xs font-medium uppercase text-tactical-500">
                      Severity
                    </th>
                    <th className="px-4 py-2 text-xs font-medium uppercase text-tactical-500">
                      Type
                    </th>
                    <th className="px-4 py-2 text-xs font-medium uppercase text-tactical-500">
                      Ranger
                    </th>
                    <th className="px-4 py-2 text-xs font-medium uppercase text-tactical-500">
                      Message
                    </th>
                    <th className="px-4 py-2 text-xs font-medium uppercase text-tactical-500">
                      Time
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {data.recent_alerts.map((a) => (
                    <AlertRow key={a.id} alert={a} />
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>

        <div className="rounded-xl border border-tactical-700/50 bg-tactical-900/60">
          <div className="border-b border-tactical-800 px-5 py-3">
            <h3 className="text-sm font-semibold text-tactical-200">
              Recent Patrols
            </h3>
          </div>
          {data.recent_patrols.length === 0 ? (
            <div className="px-5 py-8 text-center text-sm text-tactical-500">
              No recent patrols
            </div>
          ) : (
            <div className="divide-y divide-tactical-800">
              {data.recent_patrols.map((p) => (
                <div
                  key={p.id}
                  className="flex items-center justify-between px-5 py-3 transition-colors hover:bg-tactical-800/30"
                >
                  <div>
                    <p className="text-sm font-medium text-tactical-200">
                      {p.ranger_callsign}
                    </p>
                    <p className="text-xs text-tactical-500">
                      {format(new Date(p.start_time), "dd MMM HH:mm")}
                      {p.end_time &&
                        ` - ${format(new Date(p.end_time), "HH:mm")}`}
                    </p>
                  </div>
                  <div className="text-right">
                    <p className="text-sm font-semibold text-forest-400">
                      {p.distance_km.toFixed(1)} km
                    </p>
                    <p className="text-xs text-tactical-500">
                      {p.coverage_km2.toFixed(2)} km2 covered
                    </p>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

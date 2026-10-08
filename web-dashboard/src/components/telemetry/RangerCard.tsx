"use client";

import { formatDistanceToNow } from "date-fns";
import type { Ranger } from "@/lib/api";

const MODE_BADGE: Record<string, string> = {
  VEHICLE: "badge-vehicle",
  PEDESTRIAN: "badge-walking",
  STATIONARY: "badge-stationary",
  UNKNOWN_OOD: "badge bg-yellow-900/60 text-yellow-400 ring-1 ring-yellow-500/30",
};

const GNSS_DOT: Record<string, string> = {
  GOOD: "bg-forest-500",
  DEGRADED: "bg-yellow-500",
  LOST: "bg-red-500",
};

interface RangerCardProps {
  ranger: Ranger;
  compact?: boolean;
  onClick?: (ranger: Ranger) => void;
}

export default function RangerCard({ ranger, compact, onClick }: RangerCardProps) {
  const isSOS = ranger.is_sos;
  const borderClass = isSOS
    ? "border-red-500/60 bg-red-950/20"
    : "border-tactical-700/50 bg-tactical-900/60";

  return (
    <div
      onClick={() => onClick?.(ranger)}
      className={`rounded-lg border p-3 transition-all ${borderClass} ${onClick ? "cursor-pointer hover:border-forest-600/40" : ""} ${isSOS ? "animate-pulse" : ""}`}
    >
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          {isSOS && (
            <span className="h-2.5 w-2.5 rounded-full bg-red-500 animate-ping" />
          )}
          <span className="text-sm font-bold text-tactical-100">
            {ranger.callsign}
          </span>
        </div>
        <span className={`badge ${MODE_BADGE[ranger.mode] || "badge-stationary"}`}>
          {ranger.mode}
        </span>
      </div>

      {!compact && (
        <div className="mt-2.5 grid grid-cols-2 gap-x-4 gap-y-1.5">
          <div className="flex items-center justify-between">
            <span className="text-[10px] uppercase text-tactical-500">
              Speed
            </span>
            <span className="text-xs font-semibold tabular-nums text-tactical-200">
              {ranger.speed_kmh.toFixed(1)} km/h
            </span>
          </div>

          <div className="flex items-center justify-between">
            <span className="text-[10px] uppercase text-tactical-500">
              Battery
            </span>
            <span
              className={`text-xs font-semibold tabular-nums ${
                ranger.battery_pct <= 15
                  ? "text-red-400"
                  : ranger.battery_pct <= 35
                    ? "text-yellow-400"
                    : "text-forest-400"
              }`}
            >
              {ranger.battery_pct}%
            </span>
          </div>

          <div className="flex items-center justify-between">
            <span className="text-[10px] uppercase text-tactical-500">
              GNSS
            </span>
            <div className="flex items-center gap-1.5">
              <span
                className={`h-1.5 w-1.5 rounded-full ${GNSS_DOT[ranger.gnss_quality] || GNSS_DOT.LOST}`}
              />
              <span className="text-xs text-tactical-300">
                {ranger.gnss_quality}
              </span>
            </div>
          </div>

          <div className="flex items-center justify-between">
            <span className="text-[10px] uppercase text-tactical-500">
              Conf.
            </span>
            <span className="text-xs tabular-nums text-tactical-300">
              &plusmn;{ranger.confidence_radius_m.toFixed(1)} m
            </span>
          </div>
        </div>
      )}

      <div className="mt-2 text-[10px] text-tactical-600">
        {formatDistanceToNow(new Date(ranger.last_update), {
          addSuffix: true,
        })}
      </div>
    </div>
  );
}

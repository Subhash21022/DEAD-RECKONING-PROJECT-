"use client";

import { useEffect, useRef } from "react";
import { format } from "date-fns";
import type { Alert } from "@/lib/api";

interface SOSBannerProps {
  alerts: Alert[];
  onViewMap: (alert: Alert) => void;
  onAcknowledge: (alertId: string) => void;
}

export default function SOSBanner({
  alerts,
  onViewMap,
  onAcknowledge,
}: SOSBannerProps) {
  const audioRef = useRef<HTMLAudioElement | null>(null);

  const activeSOSAlerts = alerts.filter(
    (a) => a.alert_type === "SOS" && !a.is_resolved
  );

  useEffect(() => {
    if (activeSOSAlerts.length === 0) return;

    if (!audioRef.current) {
      audioRef.current = new Audio(
        "data:audio/wav;base64,UklGRnoGAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQoGAACBhYqFbF1sZ3F5gHGBe3+AfX5/gIF/gIGBgH9/fn9+f4CBf4B/f39/f3+AgICAgH9/f39/gICAgICAf39/f39/f4CAgICAgH9/f39/f39/gICAgICAgH9/f3+AgA=="
      );
    }

    audioRef.current.loop = true;
    audioRef.current.volume = 0.5;
    audioRef.current.play().catch(() => {});

    return () => {
      if (audioRef.current) {
        audioRef.current.pause();
        audioRef.current.currentTime = 0;
      }
    };
  }, [activeSOSAlerts.length]);

  if (activeSOSAlerts.length === 0) return null;

  return (
    <div className="animate-pulse-sos border-b border-red-800">
      {activeSOSAlerts.map((alert) => (
        <div
          key={alert.id}
          className="flex items-center justify-between px-5 py-3"
        >
          <div className="flex items-center gap-4">
            <div className="flex items-center gap-2">
              <svg
                className="h-5 w-5 text-white"
                fill="none"
                viewBox="0 0 24 24"
                strokeWidth={2}
                stroke="currentColor"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126ZM12 15.75h.007v.008H12v-.008Z"
                />
              </svg>
              <span className="text-sm font-black uppercase tracking-wider text-white">
                SOS EMERGENCY
              </span>
            </div>

            <div className="text-sm text-red-100">
              <span className="font-bold">{alert.ranger_callsign}</span>
              {" — "}
              <span className="text-red-200">{alert.message}</span>
              <span className="ml-2 text-xs text-red-300">
                {format(new Date(alert.created_at), "HH:mm:ss")}
              </span>
            </div>
          </div>

          <div className="flex items-center gap-2">
            <button
              onClick={() => onViewMap(alert)}
              className="rounded-md bg-white/20 px-3 py-1 text-xs font-semibold text-white backdrop-blur-sm transition-colors hover:bg-white/30"
            >
              View on Map
            </button>
            <button
              onClick={() => onAcknowledge(alert.id)}
              className="rounded-md bg-red-900/60 px-3 py-1 text-xs font-semibold text-red-100 ring-1 ring-red-600 transition-colors hover:bg-red-900"
            >
              Acknowledge
            </button>
          </div>
        </div>
      ))}
    </div>
  );
}

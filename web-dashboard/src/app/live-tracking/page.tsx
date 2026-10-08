"use client";

import { useState, useCallback, useRef, useEffect } from "react";
import maplibregl from "maplibre-gl";
import MapLibreViewer from "@/components/map/MapLibreViewer";
import RangerMarker from "@/components/map/RangerMarker";
import GeoFenceLayer from "@/components/map/GeoFenceLayer";
import BreadcrumbTrail from "@/components/map/BreadcrumbTrail";
import RangerCard from "@/components/telemetry/RangerCard";
import SOSBanner from "@/components/telemetry/SOSBanner";
import { useWebSocket } from "@/lib/websocket";
import api, { Ranger, GeoFenceZone, Alert } from "@/lib/api";

interface TrailPoint {
  lat: number;
  lon: number;
  mode: string;
  is_outage: boolean;
}

export default function LiveTrackingPage() {
  const [map, setMap] = useState<maplibregl.Map | null>(null);
  const [rangers, setRangers] = useState<Record<string, Ranger>>({});
  const [zones, setZones] = useState<GeoFenceZone[]>([]);
  const [alerts, setAlerts] = useState<Alert[]>([]);
  const [trail, setTrail] = useState<TrailPoint[]>([]);
  const [selectedRangerId, setSelectedRangerId] = useState<string | null>(null);
  const [isSimulating, setIsSimulating] = useState(false);
  const initialLoadDone = useRef(false);
  const lastTrailPos = useRef<string>("");
  const followRanger = useRef(true);

  useEffect(() => {
    async function loadInitial() {
      try {
        const [rangerList, geoFences, alertList] = await Promise.all([
          api.getRangers(),
          api.getGeoFences(),
          api.getAlerts(),
        ]);
        const rangerMap: Record<string, Ranger> = {};
        rangerList.forEach((r) => {
          rangerMap[r.id] = r;
        });
        setRangers(rangerMap);
        setZones(geoFences);
        setAlerts(alertList);

        // Load existing breadcrumbs from the most recent patrol
        try {
          const patrols = await api.getPatrols();
          if (patrols.length > 0) {
            const latest = patrols[patrols.length - 1];
            const crumbs = await api.getPatrolBreadcrumbs(latest.id);
            const trailPts: TrailPoint[] = crumbs.map((c) => ({
              lat: c.lat,
              lon: c.lon,
              mode: c.mode,
              is_outage: c.is_outage,
            }));
            setTrail(trailPts);
          }
        } catch { /* no patrols yet */ }

        initialLoadDone.current = true;
      } catch {
        /* server offline */
      }
    }
    loadInitial();
  }, []);

  const handleMessage = useCallback((data: unknown) => {
    const msg = data as { type: string; payload: Ranger | Alert };
    if (msg.type === "ranger_update") {
      const r = msg.payload as Ranger;
      setRangers((prev) => ({ ...prev, [r.id]: r }));

      // Accumulate trail point (deduplicate by position)
      const posKey = `${r.lat.toFixed(6)},${r.lon.toFixed(6)}`;
      if (posKey !== lastTrailPos.current) {
        lastTrailPos.current = posKey;
        setTrail((prev) => [
          ...prev,
          {
            lat: r.lat,
            lon: r.lon,
            mode: r.mode,
            is_outage: r.gnss_quality === "LOST",
          },
        ]);
      }
    } else if (msg.type === "alert") {
      const a = msg.payload as Alert;
      setAlerts((prev) => {
        const existing = prev.findIndex((x) => x.id === a.id);
        if (existing >= 0) {
          const copy = [...prev];
          copy[existing] = a;
          return copy;
        }
        return [a, ...prev];
      });
    }
  }, []);

  const { state } = useWebSocket({
    url: "/ws/live",
    onMessage: handleMessage,
    onOpen: () => {},
    onClose: () => {},
  });

  const rangerList = Object.values(rangers).sort((a, b) => {
    if (a.is_sos !== b.is_sos) return a.is_sos ? -1 : 1;
    return a.callsign.localeCompare(b.callsign);
  });

  // Auto-center map on ranger when following (only during active simulation)
  useEffect(() => {
    if (!map || rangerList.length === 0 || !followRanger.current || !isSimulating) return;
    const r = rangerList[0];
    if (isFinite(r.lat) && isFinite(r.lon) && r.lat >= -90 && r.lat <= 90) {
      map.easeTo({ center: [r.lon, r.lat], duration: 600 });
    }
  }, [map, rangerList, isSimulating]);

  const handleRangerClick = useCallback(
    (ranger: Ranger) => {
      setSelectedRangerId(ranger.id);
      followRanger.current = true;
      map?.flyTo({ center: [ranger.lon, ranger.lat], zoom: 16, duration: 800 });
    },
    [map]
  );

  const handleViewSOS = useCallback(
    (alert: Alert) => {
      followRanger.current = false;
      map?.flyTo({ center: [alert.lon, alert.lat], zoom: 17, duration: 800 });
    },
    [map]
  );

  const handleAcknowledgeSOS = useCallback(async (alertId: string) => {
    try {
      await api.resolveAlert(alertId);
      setAlerts((prev) =>
        prev.map((a) =>
          a.id === alertId ? { ...a, is_resolved: true } : a
        )
      );
    } catch { /* offline */ }
  }, []);

  const handleRunSimulation = useCallback(async () => {
    setIsSimulating(true);
    followRanger.current = true;
    setTrail([]);
    lastTrailPos.current = "";
    try {
      await fetch("http://localhost:8000/api/v1/simulation/start", { method: "POST" });
    } catch (e) {
      console.error("Simulation trigger failed:", e);
    }
    setTimeout(() => setIsSimulating(false), 60000);
  }, []);

  const handleStopFollow = useCallback(() => {
    followRanger.current = false;
  }, []);

  return (
    <div className="flex h-full flex-col">
      <SOSBanner
        alerts={alerts}
        onViewMap={handleViewSOS}
        onAcknowledge={handleAcknowledgeSOS}
      />

      <div className="flex flex-1 overflow-hidden">
        <aside className="flex w-72 shrink-0 flex-col border-r border-tactical-800 bg-tactical-950">
          <div className="flex items-center justify-between border-b border-tactical-800 px-4 py-3">
            <h3 className="text-sm font-semibold text-tactical-200">
              Rangers ({rangerList.length})
            </h3>
            <div className="flex items-center gap-1.5">
              <span
                className={`h-2 w-2 rounded-full ${
                  state === "OPEN" ? "bg-forest-500" : "bg-red-500"
                }`}
              />
              <span className="text-[10px] text-tactical-500">
                {state === "OPEN" ? "LIVE" : "OFFLINE"}
              </span>
            </div>
          </div>

          <div className="border-b border-tactical-800 p-3 space-y-2">
            <button
              onClick={handleRunSimulation}
              disabled={isSimulating}
              className="w-full flex items-center justify-center gap-2 rounded-lg bg-forest-600 hover:bg-forest-500 disabled:bg-tactical-800 disabled:text-tactical-500 px-3 py-2 text-xs font-semibold text-white transition-all"
            >
              {isSimulating ? "Streaming Patrol..." : "Start Live Mission"}
            </button>
            {trail.length > 0 && (
              <div className="flex items-center justify-between text-[10px] text-tactical-400">
                <span>Trail: {trail.length} points</span>
                <button
                  onClick={() => { setTrail([]); lastTrailPos.current = ""; }}
                  className="text-tactical-500 hover:text-tactical-300"
                >
                  Clear
                </button>
              </div>
            )}
          </div>

          <div className="flex-1 space-y-2 overflow-y-auto p-3">
            {rangerList.length === 0 ? (
              <div className="py-8 text-center text-xs text-tactical-600">
                No rangers online
              </div>
            ) : (
              rangerList.map((r) => (
                <RangerCard
                  key={r.id}
                  ranger={r}
                  onClick={handleRangerClick}
                />
              ))
            )}
          </div>
        </aside>

        <div className="relative flex-1" onMouseDown={handleStopFollow}>
          <MapLibreViewer onMapReady={setMap} />

          {map && (
            <>
              <GeoFenceLayer map={map} zones={zones} />
              <BreadcrumbTrail map={map} points={trail} />
              {rangerList.map((r) => (
                <RangerMarker
                  key={r.id}
                  map={map}
                  ranger={r}
                  onClick={handleRangerClick}
                />
              ))}
            </>
          )}

          <div className="absolute bottom-4 left-4 z-10 flex gap-2">
            {[
              { label: "Vehicle", color: "bg-forest-500" },
              { label: "Walking", color: "bg-blue-500" },
              { label: "Stationary", color: "bg-tactical-500" },
              { label: "SOS", color: "bg-red-500" },
            ].map((item) => (
              <div
                key={item.label}
                className="flex items-center gap-1.5 rounded-md bg-tactical-900/80 px-2 py-1 text-[10px] text-tactical-300 backdrop-blur-sm"
              >
                <span className={`h-2 w-2 rounded-full ${item.color}`} />
                {item.label}
              </div>
            ))}
          </div>

          {trail.length > 0 && (
            <div className="absolute top-3 right-16 z-10 rounded-lg bg-tactical-900/90 px-3 py-1.5 text-[10px] text-tactical-300 backdrop-blur-sm border border-tactical-700">
              Trail: {trail.length} breadcrumbs
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

"use client";

import { useState, useEffect, useCallback, useRef } from "react";
import maplibregl from "maplibre-gl";
import { format } from "date-fns";
import MapLibreViewer from "@/components/map/MapLibreViewer";
import api, { Patrol, Breadcrumb } from "@/lib/api";

const MODE_LINE_COLORS: Record<string, string> = {
  VEHICLE: "#10b981",
  PEDESTRIAN: "#3b82f6",
  STATIONARY: "#64748b",
  UNKNOWN_OOD: "#eab308",
};

const SPEED_MULTIPLIERS = [1, 2, 5, 10];

export default function PatrolReplayPage() {
  const [map, setMap] = useState<maplibregl.Map | null>(null);
  const [patrols, setPatrols] = useState<Patrol[]>([]);
  const [selectedPatrol, setSelectedPatrol] = useState<string>("");
  const [breadcrumbs, setBreadcrumbs] = useState<Breadcrumb[]>([]);
  const [playbackIndex, setPlaybackIndex] = useState(0);
  const [isPlaying, setIsPlaying] = useState(false);
  const [speedMultiplier, setSpeedMultiplier] = useState(1);
  const [showCoverage, setShowCoverage] = useState(false);
  const animMarkerRef = useRef<maplibregl.Marker | null>(null);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    api
      .getPatrols()
      .then((data) => {
        setPatrols(data);
        if (data.length > 0) {
          setSelectedPatrol(data[data.length - 1].id || data[0].id);
        }
      })
      .catch(() => {});
  }, []);

  useEffect(() => {
    if (!selectedPatrol) {
      setBreadcrumbs([]);
      return;
    }
    api
      .getPatrolBreadcrumbs(selectedPatrol)
      .then((data) => {
        setBreadcrumbs(data);
        setPlaybackIndex(0);
        setIsPlaying(false);
      })
      .catch(() => {});
  }, [selectedPatrol]);

  useEffect(() => {
    if (!map || breadcrumbs.length === 0) return;

    const coords = breadcrumbs.map((b) => [b.lon, b.lat] as [number, number]);

    const segments: GeoJSON.Feature[] = [];
    for (let i = 0; i < breadcrumbs.length - 1; i++) {
      segments.push({
        type: "Feature",
        properties: {
          color: MODE_LINE_COLORS[breadcrumbs[i].mode] || "#64748b",
          speed: breadcrumbs[i].speed_kmh,
        },
        geometry: {
          type: "LineString",
          coordinates: [coords[i], coords[i + 1]],
        },
      });
    }

    const sourceId = "patrol-trail";
    if (map.getLayer("trail-line")) map.removeLayer("trail-line");
    if (map.getSource(sourceId)) map.removeSource(sourceId);

    map.addSource(sourceId, {
      type: "geojson",
      data: { type: "FeatureCollection", features: segments },
    });

    map.addLayer({
      id: "trail-line",
      type: "line",
      source: sourceId,
      paint: {
        "line-color": ["get", "color"],
        "line-width": 3,
        "line-opacity": 0.8,
      },
      layout: { "line-cap": "round", "line-join": "round" },
    });

    const bounds = new maplibregl.LngLatBounds();
    coords.forEach((c) => bounds.extend(c));
    map.fitBounds(bounds, { padding: 60, duration: 800 });

    return () => {
      if (map.getLayer("trail-line")) map.removeLayer("trail-line");
      if (map.getSource(sourceId)) map.removeSource(sourceId);
    };
  }, [map, breadcrumbs]);

  useEffect(() => {
    if (!map || breadcrumbs.length === 0) return;

    if (!animMarkerRef.current) {
      const el = document.createElement("div");
      el.style.width = "14px";
      el.style.height = "14px";
      el.style.borderRadius = "50%";
      el.style.backgroundColor = "#10b981";
      el.style.border = "2px solid white";
      el.style.boxShadow = "0 0 8px rgba(16, 185, 129, 0.6)";
      animMarkerRef.current = new maplibregl.Marker({ element: el }).addTo(map);
    }

    const bc = breadcrumbs[playbackIndex];
    if (bc) {
      animMarkerRef.current.setLngLat([bc.lon, bc.lat]);
    }

    return () => {
      animMarkerRef.current?.remove();
      animMarkerRef.current = null;
    };
  }, [map, breadcrumbs, playbackIndex]);

  useEffect(() => {
    if (!isPlaying || breadcrumbs.length === 0) {
      if (intervalRef.current) clearInterval(intervalRef.current);
      return;
    }

    const stepMs = Math.max(10, 100 / speedMultiplier);
    intervalRef.current = setInterval(() => {
      setPlaybackIndex((prev) => {
        if (prev >= breadcrumbs.length - 1) {
          setIsPlaying(false);
          return prev;
        }
        return prev + 1;
      });
    }, stepMs);

    return () => {
      if (intervalRef.current) clearInterval(intervalRef.current);
    };
  }, [isPlaying, speedMultiplier, breadcrumbs.length]);

  useEffect(() => {
    if (!map || !showCoverage || breadcrumbs.length === 0) {
      if (map?.getLayer("coverage-grid")) map.removeLayer("coverage-grid");
      if (map?.getSource("coverage-cells")) map.removeSource("coverage-cells");
      return;
    }

    const cellSize = 50;
    const cells = new Set<string>();
    breadcrumbs.forEach((b) => {
      const R = 6378137;
      const latM = (b.lat * Math.PI * R) / 180;
      const lonM = (b.lon * Math.PI * R * Math.cos((b.lat * Math.PI) / 180)) / 180;
      const cx = Math.floor(lonM / cellSize);
      const cy = Math.floor(latM / cellSize);
      cells.add(`${cx},${cy}`);
    });

    const features: GeoJSON.Feature[] = [];
    cells.forEach((key) => {
      const [cx, cy] = key.split(",").map(Number);
      const R = 6378137;
      const minLat = ((cy * cellSize) / R) * (180 / Math.PI);
      const maxLat = (((cy + 1) * cellSize) / R) * (180 / Math.PI);
      const cosLat = Math.cos((((minLat + maxLat) / 2) * Math.PI) / 180);
      const minLon =
        ((cx * cellSize) / (R * cosLat)) * (180 / Math.PI);
      const maxLon =
        (((cx + 1) * cellSize) / (R * cosLat)) * (180 / Math.PI);

      features.push({
        type: "Feature",
        properties: {},
        geometry: {
          type: "Polygon",
          coordinates: [
            [
              [minLon, minLat],
              [maxLon, minLat],
              [maxLon, maxLat],
              [minLon, maxLat],
              [minLon, minLat],
            ],
          ],
        },
      });
    });

    if (map.getLayer("coverage-grid")) map.removeLayer("coverage-grid");
    if (map.getSource("coverage-cells")) map.removeSource("coverage-cells");

    map.addSource("coverage-cells", {
      type: "geojson",
      data: { type: "FeatureCollection", features },
    });

    map.addLayer({
      id: "coverage-grid",
      type: "fill",
      source: "coverage-cells",
      paint: {
        "fill-color": "#10b981",
        "fill-opacity": 0.15,
        "fill-outline-color": "#059669",
      },
    });
  }, [map, showCoverage, breadcrumbs]);

  const currentBC = breadcrumbs[playbackIndex];

  return (
    <div className="flex h-full flex-col">
      <div className="border-b border-tactical-800 bg-tactical-950 px-5 py-3">
        <div className="flex items-center gap-4">
          <div>
            <label className="text-[10px] uppercase text-tactical-500">
              Patrol
            </label>
            <select
              value={selectedPatrol}
              onChange={(e) => setSelectedPatrol(e.target.value)}
              className="mt-0.5 block w-64 rounded-md border border-tactical-700 bg-tactical-900 px-3 py-1.5 text-sm text-tactical-200 focus:border-forest-500 focus:outline-none"
            >
              <option value="">Select patrol...</option>
              {patrols.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.ranger_callsign} —{" "}
                  {format(new Date(p.start_time), "dd MMM HH:mm")}
                </option>
              ))}
            </select>
          </div>

          {breadcrumbs.length > 0 && (
            <>
              <div className="flex items-center gap-2">
                <button
                  onClick={() => setIsPlaying(!isPlaying)}
                  className="flex h-8 w-8 items-center justify-center rounded-lg bg-forest-600 text-white transition-colors hover:bg-forest-500"
                >
                  {isPlaying ? (
                    <svg className="h-4 w-4" fill="currentColor" viewBox="0 0 24 24">
                      <path d="M6 4h4v16H6V4zm8 0h4v16h-4V4z" />
                    </svg>
                  ) : (
                    <svg className="h-4 w-4" fill="currentColor" viewBox="0 0 24 24">
                      <path d="M8 5v14l11-7z" />
                    </svg>
                  )}
                </button>
                {SPEED_MULTIPLIERS.map((s) => (
                  <button
                    key={s}
                    onClick={() => setSpeedMultiplier(s)}
                    className={`rounded-md px-2 py-1 text-xs font-medium transition-colors ${
                      speedMultiplier === s
                        ? "bg-forest-600 text-white"
                        : "bg-tactical-800 text-tactical-400 hover:text-tactical-200"
                    }`}
                  >
                    {s}x
                  </button>
                ))}
              </div>

              <div className="flex-1">
                <input
                  type="range"
                  min={0}
                  max={breadcrumbs.length - 1}
                  value={playbackIndex}
                  onChange={(e) => {
                    setPlaybackIndex(parseInt(e.target.value));
                    setIsPlaying(false);
                  }}
                  className="w-full accent-forest-500"
                />
              </div>

              <label className="flex cursor-pointer items-center gap-2 text-xs text-tactical-400">
                <input
                  type="checkbox"
                  checked={showCoverage}
                  onChange={(e) => setShowCoverage(e.target.checked)}
                  className="accent-forest-500"
                />
                Coverage Grid
              </label>
            </>
          )}
        </div>
      </div>

      <div className="flex flex-1 overflow-hidden">
        <div className="flex-1">
          <MapLibreViewer onMapReady={setMap} />
        </div>

        {currentBC && (
          <aside className="flex w-56 shrink-0 flex-col border-l border-tactical-800 bg-tactical-950">
            <div className="border-b border-tactical-800 px-4 py-3">
              <h4 className="text-xs font-semibold uppercase text-tactical-400">
                Telemetry
              </h4>
            </div>
            <div className="space-y-3 p-4 text-sm">
              <div>
                <span className="text-[10px] uppercase text-tactical-500">
                  Point
                </span>
                <p className="font-mono text-xs text-tactical-200">
                  {playbackIndex + 1} / {breadcrumbs.length}
                </p>
              </div>
              <div>
                <span className="text-[10px] uppercase text-tactical-500">
                  Speed
                </span>
                <p className="text-lg font-bold tabular-nums text-forest-400">
                  {currentBC.speed_kmh.toFixed(1)}{" "}
                  <span className="text-xs font-normal text-tactical-500">
                    km/h
                  </span>
                </p>
              </div>
              <div>
                <span className="text-[10px] uppercase text-tactical-500">
                  Heading
                </span>
                <p className="font-mono text-xs text-tactical-200">
                  {currentBC.heading_deg.toFixed(1)}deg
                </p>
              </div>
              <div>
                <span className="text-[10px] uppercase text-tactical-500">
                  Mode
                </span>
                <p
                  className="text-xs font-semibold"
                  style={{
                    color:
                      MODE_LINE_COLORS[currentBC.mode] || "#64748b",
                  }}
                >
                  {currentBC.mode}
                </p>
              </div>
              <div>
                <span className="text-[10px] uppercase text-tactical-500">
                  Confidence
                </span>
                <p className="font-mono text-xs text-tactical-200">
                  &plusmn;{currentBC.confidence_m.toFixed(1)} m
                </p>
              </div>
              <div>
                <span className="text-[10px] uppercase text-tactical-500">
                  GNSS
                </span>
                <p className="text-xs text-tactical-300">
                  {currentBC.is_outage ? (
                    <span className="text-red-400">DEAD RECKONING</span>
                  ) : (
                    <span className="text-forest-400">GPS LOCK</span>
                  )}
                </p>
              </div>
              <div>
                <span className="text-[10px] uppercase text-tactical-500">
                  Position
                </span>
                <p className="font-mono text-[11px] text-tactical-300">
                  {currentBC.lat.toFixed(6)}, {currentBC.lon.toFixed(6)}
                </p>
              </div>
            </div>

            <div className="border-t border-tactical-800 p-4">
              <h4 className="mb-2 text-[10px] font-semibold uppercase text-tactical-500">
                Speed Profile
              </h4>
              <div className="flex h-20 items-end gap-px">
                {breadcrumbs
                  .filter((_, i) => i % Math.max(1, Math.floor(breadcrumbs.length / 80)) === 0)
                  .map((b, i) => {
                    const maxSpeed = Math.max(
                      1,
                      ...breadcrumbs.map((x) => x.speed_kmh)
                    );
                    const h = Math.max(1, (b.speed_kmh / maxSpeed) * 100);
                    const isCurrent =
                      i ===
                      Math.floor(
                        playbackIndex /
                          Math.max(1, Math.floor(breadcrumbs.length / 80))
                      );
                    return (
                      <div
                        key={i}
                        className="flex-1 rounded-t-sm transition-all"
                        style={{
                          height: `${h}%`,
                          backgroundColor: isCurrent
                            ? "#10b981"
                            : MODE_LINE_COLORS[b.mode] || "#334155",
                          opacity: isCurrent ? 1 : 0.5,
                        }}
                      />
                    );
                  })}
              </div>
            </div>
          </aside>
        )}
      </div>
    </div>
  );
}

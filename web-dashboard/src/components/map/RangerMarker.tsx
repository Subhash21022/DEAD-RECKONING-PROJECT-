"use client";

import { useEffect, useRef } from "react";
import maplibregl from "maplibre-gl";
import type { Ranger } from "@/lib/api";

const MODE_COLORS: Record<string, string> = {
  VEHICLE: "#10b981",
  PEDESTRIAN: "#3b82f6",
  STATIONARY: "#64748b",
  UNKNOWN_OOD: "#eab308",
};

const SOS_COLOR = "#dc2626";

function createArrowSVG(heading: number, color: string, isSOS: boolean): string {
  const pulse = isSOS
    ? `<animate attributeName="opacity" values="1;0.4;1" dur="0.8s" repeatCount="indefinite"/>`
    : "";
  return `<svg width="36" height="36" viewBox="0 0 36 36" xmlns="http://www.w3.org/2000/svg">
    <g transform="rotate(${heading}, 18, 18)">
      <circle cx="18" cy="18" r="14" fill="${color}" opacity="0.2" stroke="${color}" stroke-width="1.5">${pulse}</circle>
      <polygon points="18,4 24,26 18,21 12,26" fill="${color}" stroke="white" stroke-width="0.8"/>
    </g>
  </svg>`;
}

interface RangerMarkerProps {
  map: maplibregl.Map;
  ranger: Ranger;
  onClick?: (ranger: Ranger) => void;
}

export default function RangerMarker({ map, ranger, onClick }: RangerMarkerProps) {
  const markerRef = useRef<maplibregl.Marker | null>(null);
  const elementRef = useRef<HTMLDivElement | null>(null);
  const popupRef = useRef<maplibregl.Popup | null>(null);
  const currentBlobUrlRef = useRef<string | null>(null);
  const circleSourceId = `confidence-${ranger.id}`;

  const validCoords =
    isFinite(ranger.lat) && isFinite(ranger.lon) &&
    ranger.lat >= -90 && ranger.lat <= 90 &&
    ranger.lon >= -180 && ranger.lon <= 180;

  // 1. Initialize Marker on Mount
  useEffect(() => {
    if (!validCoords) return;

    const el = document.createElement("div");
    el.style.width = "36px";
    el.style.height = "36px";
    el.style.cursor = "pointer";
    el.style.backgroundSize = "contain";
    el.style.transition = "transform 0.3s ease-out";
    elementRef.current = el;

    const popup = new maplibregl.Popup({ offset: 20, closeButton: false });
    popupRef.current = popup;

    const marker = new maplibregl.Marker({ element: el })
      .setLngLat([ranger.lon, ranger.lat])
      .setPopup(popup)
      .addTo(map);

    markerRef.current = marker;

    return () => {
      if (currentBlobUrlRef.current) {
        URL.revokeObjectURL(currentBlobUrlRef.current);
      }
      marker.remove();
      markerRef.current = null;
      elementRef.current = null;
      popupRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [map, ranger.id]);

  // 2. Update Position, Heading SVG, Color, and Popup on Every Telemetry Update
  useEffect(() => {
    if (!validCoords || !markerRef.current || !elementRef.current) return;

    markerRef.current.setLngLat([ranger.lon, ranger.lat]);

    const isSOS = ranger.is_sos;
    const color = isSOS ? SOS_COLOR : (MODE_COLORS[ranger.mode] || MODE_COLORS.STATIONARY);

    // Generate new rotated SVG arrow
    const svgBlob = new Blob(
      [createArrowSVG(ranger.heading_deg, color, isSOS)],
      { type: "image/svg+xml" }
    );
    const newSvgUrl = URL.createObjectURL(svgBlob);
    if (currentBlobUrlRef.current) {
      URL.revokeObjectURL(currentBlobUrlRef.current);
    }
    currentBlobUrlRef.current = newSvgUrl;
    elementRef.current.style.backgroundImage = `url(${newSvgUrl})`;

    if (onClick) {
      elementRef.current.onclick = () => onClick(ranger);
    }

    if (popupRef.current) {
      popupRef.current.setHTML(`
        <div style="font-family: system-ui; font-size: 12px; line-height: 1.6;">
          <div style="font-weight: 700; font-size: 13px; margin-bottom: 4px;">${ranger.callsign}</div>
          <div><span style="color: #94a3b8;">Speed:</span> ${ranger.speed_kmh.toFixed(1)} km/h</div>
          <div><span style="color: #94a3b8;">Mode:</span> <span style="color: ${color}; font-weight: 600;">${ranger.mode}</span></div>
          <div><span style="color: #94a3b8;">GNSS:</span> ${ranger.gnss_quality}</div>
          <div><span style="color: #94a3b8;">Confidence:</span> &plusmn;${ranger.confidence_radius_m.toFixed(1)} m</div>
          <div><span style="color: #94a3b8;">Battery:</span> ${ranger.battery_pct}%</div>
          ${isSOS ? '<div style="color: #ef4444; font-weight: 700; margin-top: 4px;">!! SOS ACTIVE !!</div>' : ""}
        </div>
      `);
    }
  }, [
    validCoords,
    ranger.lat,
    ranger.lon,
    ranger.heading_deg,
    ranger.mode,
    ranger.speed_kmh,
    ranger.confidence_radius_m,
    ranger.gnss_quality,
    ranger.battery_pct,
    ranger.is_sos,
    ranger.callsign,
    onClick,
  ]);

  useEffect(() => {
    if (!validCoords) return;
    const radiusMeters = ranger.confidence_radius_m;
    const center: [number, number] = [ranger.lon, ranger.lat];
    const steps = 48;
    const coords: number[][] = [];
    for (let i = 0; i <= steps; i++) {
      const angle = (i / steps) * 2 * Math.PI;
      const dx = radiusMeters * Math.cos(angle);
      const dy = radiusMeters * Math.sin(angle);
      const dlat = dy / 111320;
      const dlon = dx / (111320 * Math.cos((ranger.lat * Math.PI) / 180));
      coords.push([center[0] + dlon, center[1] + dlat]);
    }

    const isSOS = ranger.is_sos;
    const color = isSOS ? SOS_COLOR : (MODE_COLORS[ranger.mode] || MODE_COLORS.STATIONARY);

    const geojsonData: GeoJSON.Feature = {
      type: "Feature",
      properties: {},
      geometry: { type: "Polygon", coordinates: [coords] },
    };

    const source = map.getSource(circleSourceId) as maplibregl.GeoJSONSource | undefined;
    if (source) {
      source.setData(geojsonData);
      map.setPaintProperty(`${circleSourceId}-fill`, "fill-color", color);
      map.setPaintProperty(`${circleSourceId}-line`, "line-color", color);
    } else if (map.isStyleLoaded()) {
      map.addSource(circleSourceId, { type: "geojson", data: geojsonData });
      map.addLayer({
        id: `${circleSourceId}-fill`,
        type: "fill",
        source: circleSourceId,
        paint: { "fill-color": color, "fill-opacity": 0.12 },
      });
      map.addLayer({
        id: `${circleSourceId}-line`,
        type: "line",
        source: circleSourceId,
        paint: { "line-color": color, "line-width": 1.5, "line-opacity": 0.5 },
      });
    }

    return () => {
      try {
        if (map.getStyle()) {
          if (map.getLayer(`${circleSourceId}-fill`)) map.removeLayer(`${circleSourceId}-fill`);
          if (map.getLayer(`${circleSourceId}-line`)) map.removeLayer(`${circleSourceId}-line`);
          if (map.getSource(circleSourceId)) map.removeSource(circleSourceId);
        }
      } catch { /* map already removed */ }
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ranger.lat, ranger.lon, ranger.confidence_radius_m, ranger.mode, ranger.is_sos]);

  return null;
}

"use client";

import { useEffect, useRef } from "react";
import maplibregl from "maplibre-gl";

interface TrailPoint {
  lat: number;
  lon: number;
  mode: string;
  is_outage: boolean;
}

const MODE_COLORS: Record<string, string> = {
  VEHICLE: "#10b981",
  PEDESTRIAN: "#3b82f6",
  STATIONARY: "#64748b",
  UNKNOWN_OOD: "#eab308",
};

interface BreadcrumbTrailProps {
  map: maplibregl.Map;
  points: TrailPoint[];
}

export default function BreadcrumbTrail({ map, points }: BreadcrumbTrailProps) {
  const sourceId = "breadcrumb-trail";
  const layerId = "breadcrumb-trail-line";
  const dotSourceId = "breadcrumb-dots";
  const dotLayerId = "breadcrumb-dots-layer";
  const addedRef = useRef(false);

  useEffect(() => {
    if (points.length < 2) return;
    if (!map.isStyleLoaded()) return;

    const segments: GeoJSON.Feature[] = [];
    for (let i = 0; i < points.length - 1; i++) {
      const p = points[i];
      const q = points[i + 1];
      if (!isFinite(p.lat) || !isFinite(p.lon) || !isFinite(q.lat) || !isFinite(q.lon)) continue;
      segments.push({
        type: "Feature",
        properties: {
          color: MODE_COLORS[p.mode] || MODE_COLORS.STATIONARY,
          outage: p.is_outage,
        },
        geometry: {
          type: "LineString",
          coordinates: [[p.lon, p.lat], [q.lon, q.lat]],
        },
      });
    }

    const trailData: GeoJSON.FeatureCollection = {
      type: "FeatureCollection",
      features: segments,
    };

    const dotFeatures: GeoJSON.Feature[] = points
      .filter((p) => isFinite(p.lat) && isFinite(p.lon))
      .map((p) => ({
        type: "Feature",
        properties: {
          color: MODE_COLORS[p.mode] || MODE_COLORS.STATIONARY,
        },
        geometry: {
          type: "Point",
          coordinates: [p.lon, p.lat],
        },
      }));

    const dotData: GeoJSON.FeatureCollection = {
      type: "FeatureCollection",
      features: dotFeatures,
    };

    try {
      const trailSrc = map.getSource(sourceId) as maplibregl.GeoJSONSource | undefined;
      if (trailSrc) {
        trailSrc.setData(trailData);
      } else {
        map.addSource(sourceId, { type: "geojson", data: trailData });
        map.addLayer({
          id: layerId,
          type: "line",
          source: sourceId,
          paint: {
            "line-color": ["get", "color"],
            "line-width": 3,
            "line-opacity": 0.85,
          },
          layout: {
            "line-cap": "round",
            "line-join": "round",
          },
        });
      }

      const dotSrc = map.getSource(dotSourceId) as maplibregl.GeoJSONSource | undefined;
      if (dotSrc) {
        dotSrc.setData(dotData);
      } else {
        map.addSource(dotSourceId, { type: "geojson", data: dotData });
        map.addLayer({
          id: dotLayerId,
          type: "circle",
          source: dotSourceId,
          paint: {
            "circle-radius": 4,
            "circle-color": ["get", "color"],
            "circle-stroke-width": 1.5,
            "circle-stroke-color": "#ffffff",
            "circle-opacity": 0.9,
          },
        });
      }
      addedRef.current = true;
    } catch {
      /* style not ready */
    }

    return () => {
      try {
        if (map.getStyle()) {
          if (map.getLayer(dotLayerId)) map.removeLayer(dotLayerId);
          if (map.getSource(dotSourceId)) map.removeSource(dotSourceId);
          if (map.getLayer(layerId)) map.removeLayer(layerId);
          if (map.getSource(sourceId)) map.removeSource(sourceId);
        }
      } catch { /* map removed */ }
      addedRef.current = false;
    };
  }, [map, points.length]);

  return null;
}

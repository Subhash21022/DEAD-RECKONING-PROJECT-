"use client";

import { useEffect } from "react";
import maplibregl from "maplibre-gl";
import type { GeoFenceZone } from "@/lib/api";

const ZONE_COLORS: Record<string, { fill: string; stroke: string }> = {
  CORE_PROTECTED: { fill: "rgba(16, 185, 129, 0.12)", stroke: "#10b981" },
  BUFFER_ZONE: { fill: "rgba(234, 179, 8, 0.10)", stroke: "#eab308" },
  POACHING_RISK: { fill: "rgba(239, 68, 68, 0.12)", stroke: "#ef4444" },
};

interface GeoFenceLayerProps {
  map: maplibregl.Map;
  zones: GeoFenceZone[];
}

export default function GeoFenceLayer({ map, zones }: GeoFenceLayerProps) {
  useEffect(() => {
    if (zones.length === 0) return;

    const sourceId = "geofence-zones";
    const fillLayerId = "geofence-fill";
    const lineLayerId = "geofence-line";
    const labelLayerId = "geofence-label";

    function applyLayers() {
      if (!map.isStyleLoaded()) return;

      const features: GeoJSON.Feature[] = zones.map((zone) => ({
        type: "Feature",
        properties: {
          name: zone.name,
          zone_type: zone.zone_type,
          fillColor:
            ZONE_COLORS[zone.zone_type]?.fill || ZONE_COLORS.CORE_PROTECTED.fill,
          strokeColor:
            ZONE_COLORS[zone.zone_type]?.stroke ||
            ZONE_COLORS.CORE_PROTECTED.stroke,
        },
        geometry: zone.polygon,
      }));

      const geojson: GeoJSON.FeatureCollection = {
        type: "FeatureCollection",
        features,
      };

      if (map.getSource(sourceId)) {
        (map.getSource(sourceId) as maplibregl.GeoJSONSource).setData(geojson);
        return;
      }

      map.addSource(sourceId, { type: "geojson", data: geojson });

      map.addLayer({
        id: fillLayerId,
        type: "fill",
        source: sourceId,
        paint: {
          "fill-color": ["get", "fillColor"],
          "fill-opacity": 1,
        },
      });

      map.addLayer({
        id: lineLayerId,
        type: "line",
        source: sourceId,
        paint: {
          "line-color": ["get", "strokeColor"],
          "line-width": 2,
          "line-dasharray": [4, 2],
        },
      });

      try {
        map.addLayer({
          id: labelLayerId,
          type: "symbol",
          source: sourceId,
          layout: {
            "text-field": ["get", "name"],
            "text-size": 11,
            "text-font": ["Open Sans Regular"],
            "text-anchor": "center",
            "text-allow-overlap": false,
          },
          paint: {
            "text-color": "#e2e8f0",
            "text-halo-color": "#0f172a",
            "text-halo-width": 1.5,
          },
        });
      } catch {
        /* glyphs not available — skip labels */
      }
    }

    if (map.isStyleLoaded()) {
      applyLayers();
    } else {
      map.once("load", applyLayers);
    }

    const popup = new maplibregl.Popup({
      closeButton: false,
      closeOnClick: false,
    });

    const onMouseEnter = (
      e: maplibregl.MapMouseEvent & { features?: maplibregl.MapGeoJSONFeature[] }
    ) => {
      map.getCanvas().style.cursor = "pointer";
      const props = e.features?.[0]?.properties;
      if (!props) return;
      popup
        .setLngLat(e.lngLat)
        .setHTML(
          `<div style="font-family: system-ui; font-size: 12px;">
            <div style="font-weight: 700;">${props.name}</div>
            <div style="color: #94a3b8; margin-top: 2px;">${props.zone_type.replace(/_/g, " ")}</div>
          </div>`
        )
        .addTo(map);
    };

    const onMouseLeave = () => {
      map.getCanvas().style.cursor = "";
      popup.remove();
    };

    map.on("mouseenter", fillLayerId, onMouseEnter);
    map.on("mouseleave", fillLayerId, onMouseLeave);

    return () => {
      map.off("load", applyLayers);
      try {
        map.off("mouseenter", fillLayerId, onMouseEnter);
        map.off("mouseleave", fillLayerId, onMouseLeave);
      } catch { /* map already removed */ }
      popup.remove();
      try {
        if (map.getStyle()) {
          if (map.getLayer(labelLayerId)) map.removeLayer(labelLayerId);
          if (map.getLayer(lineLayerId)) map.removeLayer(lineLayerId);
          if (map.getLayer(fillLayerId)) map.removeLayer(fillLayerId);
          if (map.getSource(sourceId)) map.removeSource(sourceId);
        }
      } catch { /* map already removed */ }
    };
  }, [map, zones]);

  return null;
}

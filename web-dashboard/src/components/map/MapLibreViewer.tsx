"use client";

import { useRef, useEffect, useState, ReactNode } from "react";
import maplibregl from "maplibre-gl";
import "maplibre-gl/dist/maplibre-gl.css";

interface MapLibreViewerProps {
  center?: [number, number];
  zoom?: number;
  children?: ReactNode;
  onMapReady?: (map: maplibregl.Map) => void;
  className?: string;
}

const BANDIPUR_CENTER: [number, number] = [77.595, 12.973];
const DEFAULT_ZOOM = 14;

const GLYPHS_URL =
  "https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf";

const TERRAIN_STYLE: maplibregl.StyleSpecification = {
  version: 8,
  name: "Forest Tactical",
  glyphs: GLYPHS_URL,
  sources: {
    osm: {
      type: "raster",
      tiles: ["https://tile.openstreetmap.org/{z}/{x}/{y}.png"],
      tileSize: 256,
      attribution: "&copy; OpenStreetMap contributors",
    },
  },
  layers: [
    {
      id: "osm-tiles",
      type: "raster",
      source: "osm",
      minzoom: 0,
      maxzoom: 19,
    },
  ],
};

const SATELLITE_STYLE: maplibregl.StyleSpecification = {
  version: 8,
  name: "Satellite",
  glyphs: GLYPHS_URL,
  sources: {
    satellite: {
      type: "raster",
      tiles: [
        "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
      ],
      tileSize: 256,
      attribution: "&copy; Esri",
    },
  },
  layers: [
    {
      id: "satellite-tiles",
      type: "raster",
      source: "satellite",
      minzoom: 0,
      maxzoom: 19,
    },
  ],
};

export default function MapLibreViewer({
  center = BANDIPUR_CENTER,
  zoom = DEFAULT_ZOOM,
  onMapReady,
  className = "",
}: MapLibreViewerProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<maplibregl.Map | null>(null);
  const [isSatellite, setIsSatellite] = useState(false);

  useEffect(() => {
    if (!containerRef.current || mapRef.current) return;

    const map = new maplibregl.Map({
      container: containerRef.current,
      style: TERRAIN_STYLE,
      center,
      zoom,
      attributionControl: false,
    });

    map.addControl(
      new maplibregl.AttributionControl({ compact: true }),
      "bottom-left"
    );
    map.addControl(new maplibregl.ScaleControl({ unit: "metric" }), "bottom-right");
    map.addControl(new maplibregl.FullscreenControl(), "top-right");
    map.addControl(new maplibregl.NavigationControl(), "top-right");

    mapRef.current = map;

    map.on("load", () => {
      onMapReady?.(map);
    });

    return () => {
      map.remove();
      mapRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (!mapRef.current) return;
    mapRef.current.setStyle(isSatellite ? SATELLITE_STYLE : TERRAIN_STYLE);
  }, [isSatellite]);

  return (
    <div className={`relative h-full w-full ${className}`}>
      <div ref={containerRef} className="h-full w-full" />
      <button
        onClick={() => setIsSatellite(!isSatellite)}
        className="absolute left-3 top-3 z-10 rounded-lg border border-tactical-600 bg-tactical-900/90 px-3 py-1.5 text-xs font-medium text-tactical-200 backdrop-blur-sm transition-colors hover:bg-tactical-800"
      >
        {isSatellite ? "Terrain" : "Satellite"}
      </button>
    </div>
  );
}

export { BANDIPUR_CENTER, DEFAULT_ZOOM };

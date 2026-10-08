"use client";

import { useEffect, useRef, useState, useCallback } from "react";

export type ConnectionState = "CONNECTING" | "OPEN" | "CLOSED";

interface UseWebSocketOptions {
  url: string;
  onMessage: (data: unknown) => void;
  onOpen?: () => void;
  onClose?: () => void;
  enabled?: boolean;
}

interface UseWebSocketReturn {
  state: ConnectionState;
  send: (data: unknown) => void;
  reconnect: () => void;
}

const BASE_DELAY_MS = 1000;
const MAX_DELAY_MS = 30000;
const MAX_RETRIES = 20;

export function useWebSocket({
  url,
  onMessage,
  onOpen,
  onClose,
  enabled = true,
}: UseWebSocketOptions): UseWebSocketReturn {
  const [state, setState] = useState<ConnectionState>("CLOSED");
  const wsRef = useRef<WebSocket | null>(null);
  const retryCountRef = useRef(0);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const onMessageRef = useRef(onMessage);
  const onOpenRef = useRef(onOpen);
  const onCloseRef = useRef(onClose);

  onMessageRef.current = onMessage;
  onOpenRef.current = onOpen;
  onCloseRef.current = onClose;

  const clearTimer = useCallback(() => {
    if (timerRef.current) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  const connect = useCallback(() => {
    if (!enabled) return;
    clearTimer();

    if (wsRef.current) {
      wsRef.current.onclose = null;
      wsRef.current.close();
    }

    setState("CONNECTING");

    const wsUrl =
      process.env.NEXT_PUBLIC_WS_URL || "ws://localhost:8000";
    const fullUrl = `${wsUrl}${url}`;
    const ws = new WebSocket(fullUrl);
    wsRef.current = ws;

    ws.onopen = () => {
      setState("OPEN");
      retryCountRef.current = 0;
      onOpenRef.current?.();
    };

    ws.onmessage = (event) => {
      try {
        const parsed = JSON.parse(event.data);
        onMessageRef.current(parsed);
      } catch {
        onMessageRef.current(event.data);
      }
    };

    ws.onclose = () => {
      setState("CLOSED");
      wsRef.current = null;
      onCloseRef.current?.();

      if (enabled && retryCountRef.current < MAX_RETRIES) {
        const delay = Math.min(
          BASE_DELAY_MS * Math.pow(2, retryCountRef.current),
          MAX_DELAY_MS
        );
        retryCountRef.current += 1;
        timerRef.current = setTimeout(connect, delay);
      }
    };

    ws.onerror = () => {
      ws.close();
    };
  }, [url, enabled, clearTimer]);

  useEffect(() => {
    connect();
    return () => {
      clearTimer();
      if (wsRef.current) {
        wsRef.current.onclose = null;
        wsRef.current.close();
        wsRef.current = null;
      }
      setState("CLOSED");
    };
  }, [connect, clearTimer]);

  const send = useCallback((data: unknown) => {
    if (wsRef.current?.readyState === WebSocket.OPEN) {
      wsRef.current.send(
        typeof data === "string" ? data : JSON.stringify(data)
      );
    }
  }, []);

  const reconnect = useCallback(() => {
    retryCountRef.current = 0;
    connect();
  }, [connect]);

  return { state, send, reconnect };
}

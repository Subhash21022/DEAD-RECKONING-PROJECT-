import json
import uuid
import asyncio
from typing import Dict
from fastapi import WebSocket


class ConnectionManager:
    def __init__(self) -> None:
        self.active: Dict[str, WebSocket] = {}
        self._lock = asyncio.Lock()

    async def connect(self, websocket: WebSocket, ranger_id: uuid.UUID) -> None:
        await websocket.accept()
        key = str(ranger_id)
        async with self._lock:
            old = self.active.get(key)
            if old is not None:
                try:
                    await old.close(code=1000)
                except Exception:
                    pass
            self.active[key] = websocket

    async def disconnect(self, ranger_id: uuid.UUID) -> None:
        key = str(ranger_id)
        async with self._lock:
            self.active.pop(key, None)

    async def send_to_ranger(self, ranger_id: uuid.UUID, message: dict) -> None:
        key = str(ranger_id)
        ws = self.active.get(key)
        if ws is not None:
            try:
                await ws.send_json(message)
            except Exception:
                async with self._lock:
                    self.active.pop(key, None)

    async def broadcast_to_all(self, message: dict) -> None:
        dead: list[str] = []
        for key, ws in list(self.active.items()):
            try:
                await ws.send_json(message)
            except Exception:
                dead.append(key)
        if dead:
            async with self._lock:
                for key in dead:
                    self.active.pop(key, None)

    async def broadcast_alert(self, alert_data: dict) -> None:
        envelope = {"type": "ALERT", "payload": alert_data}
        await self.broadcast_to_all(envelope)

    @property
    def connection_count(self) -> int:
        return len(self.active)

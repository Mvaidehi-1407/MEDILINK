from collections import defaultdict
from typing import Any, DefaultDict

from fastapi import WebSocket
from fastapi.encoders import jsonable_encoder


class ConnectionManager:
    def __init__(self) -> None:
        self.active: DefaultDict[str, set[WebSocket]] = defaultdict(set)

    async def connect(self, channel: str, websocket: WebSocket) -> None:
        await websocket.accept()
        self.active[channel].add(websocket)

    def register(self, channel: str, websocket: WebSocket) -> None:
        """Track an already-accepted socket (accept happens earlier so auth can run first)."""
        self.active[channel].add(websocket)

    def disconnect(self, channel: str, websocket: WebSocket) -> None:
        self.active[channel].discard(websocket)

    def is_connected(self, channel: str) -> bool:
        return len(self.active[channel]) > 0

    async def broadcast(self, channel: str, event: str, payload: Any) -> int:
        # jsonable_encoder handles datetime/ObjectId/etc in payloads that came straight from a
        # Mongo document -- send_json()'s default json.dumps cannot, and would otherwise fail
        # silently (caught below) and quietly drop the client from the channel.
        message = jsonable_encoder({"event": event, "data": payload})
        disconnected: list[WebSocket] = []
        delivered = 0
        for ws in list(self.active[channel]):
            try:
                await ws.send_json(message)
                delivered += 1
            except Exception:
                disconnected.append(ws)
        for ws in disconnected:
            self.disconnect(channel, ws)
        return delivered


manager = ConnectionManager()


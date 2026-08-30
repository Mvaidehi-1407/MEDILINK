from collections import defaultdict
from typing import Any, DefaultDict

from fastapi import WebSocket


class ConnectionManager:
    def __init__(self) -> None:
        self.active: DefaultDict[str, set[WebSocket]] = defaultdict(set)

    async def connect(self, channel: str, websocket: WebSocket) -> None:
        await websocket.accept()
        self.active[channel].add(websocket)

    def disconnect(self, channel: str, websocket: WebSocket) -> None:
        self.active[channel].discard(websocket)

    async def broadcast(self, channel: str, event: str, payload: Any) -> None:
        disconnected: list[WebSocket] = []
        for ws in list(self.active[channel]):
            try:
                await ws.send_json({"event": event, "data": payload})
            except Exception:
                disconnected.append(ws)
        for ws in disconnected:
            self.disconnect(channel, ws)


manager = ConnectionManager()


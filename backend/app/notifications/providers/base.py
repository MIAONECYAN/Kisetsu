from __future__ import annotations

from abc import ABC, abstractmethod

from app.notifications.models import NotificationEvent, NotificationSettings


class NotificationProvider(ABC):
    name: str

    @abstractmethod
    async def send(self, event: NotificationEvent, settings: NotificationSettings) -> None:
        raise NotImplementedError


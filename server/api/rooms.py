"""等候区 + 事件广播（2026-09-27，第 4 步）。都只在内存里，按窗口一个 Room。

等候区：app 发来一句先排着，「等 TA 说完」——安静满 reply_wait 秒才把排着的几条用换行拼成一句跑一轮；
每来一条重新计时。同一个窗口同时只跑一轮，跑的时候新来的接着排，跑完再按最后一条的时间算够没够。
服务器重启丢了等候区也没关系：app 本地先显示，30 秒没收到这一轮的事件就带同一个 client_id 重发，这里去重。

事件广播：一轮里的事件（typing / thinking / card / bubble / recall / usage / error / done …）推给这个窗口所有
连着的事件流；private 的卡片不推（那是给它自己看的，比如「关于 TA」记了什么）。"""
from __future__ import annotations

import asyncio
import logging
from collections import deque
from dataclasses import dataclass, field
from typing import Awaitable, Callable
from uuid import UUID

log = logging.getLogger(__name__)

SEEN_IDS = 200                 # 每个窗口记最近多少个 client_id 用来去重
Runner = Callable[[str, bool, Callable[[dict], Awaitable[None]], list, list], Awaitable[None]]
# runner(text, resend, emit, attachments, parts)：真正跑一轮（run_turn + 记最后活跃时间），由接口那层给；
# parts = 拼成 text 之前那几句，存下来让 app 还原成几个气泡


@dataclass
class Room:
    pending: list[str] = field(default_factory=list)
    files: list = field(default_factory=list)          # 跟着排着的话一起来的附件编号
    last_at: float = 0.0                      # 最后一条进来的时间（loop.time()）
    wait: float = 0.0
    timer: asyncio.Task | None = None
    running: asyncio.Task | None = None
    seen: deque = field(default_factory=lambda: deque(maxlen=SEEN_IDS))
    listeners: set = field(default_factory=set)       # 每个事件流一个 asyncio.Queue
    runner: Runner | None = None                      # 最近一次 submit 给的，醒来那轮跑完接着处理排着的用


class Rooms:
    def __init__(self, wait_scale: float = 1.0):
        self.rooms: dict[UUID, Room] = {}
        self.wait_scale = wait_scale              # 测试里调小，不用真等十秒

    def room(self, conv: UUID) -> Room:
        return self.rooms.setdefault(conv, Room())

    def busy(self, conv: UUID) -> bool:
        r = self.rooms.get(conv)
        return bool(r and (r.pending or r.files or (r.running and not r.running.done())))

    # ── 广播 ──

    def watched(self, conv: UUID) -> bool:
        """有没有人正连着这个窗口的事件流（聊天页开着）。没人看时它回的话要推送。"""
        r = self.rooms.get(conv)
        return bool(r and r.listeners)

    def listen(self, conv: UUID) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue()
        self.room(conv).listeners.add(q)
        return q

    def unlisten(self, conv: UUID, q: asyncio.Queue) -> None:
        r = self.rooms.get(conv)
        if r:
            r.listeners.discard(q)

    async def publish(self, conv: UUID, ev: dict) -> None:
        if ev.get("type") == "card" and ev.get("private"):
            return
        for q in list(self.room(conv).listeners):
            q.put_nowait(ev)

    # ── 等候区 ──

    def submit(self, conv: UUID, text: str, client_id: str | None, wait_seconds: float, runner: Runner,
               attachments: list | None = None) -> bool:
        """排进等候区。同一个 client_id 来过就不再排（app 重发），返回 False。"""
        r = self.room(conv)
        if client_id:
            if client_id in r.seen:
                return False
            r.seen.append(client_id)
        loop = asyncio.get_running_loop()
        r.runner = runner
        if text:
            r.pending.append(text)
        r.files.extend(attachments or [])
        r.last_at = loop.time()
        r.wait = wait_seconds * self.wait_scale
        idle = not (r.running and not r.running.done()) and not (r.timer and not r.timer.done())
        if idle:                         # 已经在等的话不用动：计时器醒来会按新的 last_at 接着等
            self._arm(conv, r)
        return True

    def run_now(self, conv: UUID, runner: Runner, *, resend: bool) -> None:
        """不进等候区直接跑（倒回之后的重新回）。调用方先确认这个窗口不忙。"""
        r = self.room(conv)
        r.running = asyncio.create_task(self._run(conv, r, [], resend, runner, []))

    def _arm(self, conv: UUID, r: Room) -> None:
        if r.timer and not r.timer.done():
            r.timer.cancel()
        r.timer = asyncio.create_task(self._wait_then_run(conv, r))

    async def _wait_then_run(self, conv: UUID, r: Room) -> None:
        loop = asyncio.get_running_loop()
        while (left := r.last_at + r.wait - loop.time()) > 0:
            await asyncio.sleep(left)
        parts, files = list(r.pending), list(r.files)
        r.pending.clear()
        r.files.clear()
        r.timer = None
        r.running = asyncio.current_task()
        await self._run(conv, r, parts, False, r.runner, files)

    async def _run(self, conv: UUID, r: Room, parts: list[str], resend: bool, runner: Runner, files: list) -> None:
        async def emit(ev: dict) -> None:
            await self.publish(conv, ev)
        try:
            await runner("\n".join(parts), resend, emit, files, parts)
        except Exception as e:           # 服务器自己的 bug 也要让 app 知道，别让它一直转圈
            log.exception("turn crashed")
            await emit({"type": "error", "kind": "server", "message": f"服务器出错：{e}"})
            await emit({"type": "done"})
        finally:
            r.running = None
            if r.pending or r.files:     # 跑的时候又来了几句：按最后一条的时间接着等
                self._arm(conv, r)

    async def run_exclusive(self, conv: UUID, fn) -> tuple[bool, object]:
        """巡逻醒来用：这个窗口不忙就占着跑 fn(emit)，返回 (True, fn 的结果)；忙就不跑，返回 (False, None)。
        fn 在自己的任务里跑——窗口被删时 drop 取消的是它，不会误伤巡逻的循环；那时返回 (True, None)。
        跑的时候 TA 发来的话照常排着，跑完接着处理。"""
        if self.busy(conv):
            return False, None
        r = self.room(conv)

        async def emit(ev: dict) -> None:
            await self.publish(conv, ev)
        task = asyncio.create_task(fn(emit))
        r.running = task
        try:
            return True, await task
        except asyncio.CancelledError:
            if task.cancelled() and not asyncio.current_task().cancelling():
                return True, None
            raise
        finally:
            if r.running is task:
                r.running = None
            if (r.pending or r.files) and r.runner and self.rooms.get(conv) is r:
                self._arm(conv, r)

    def drop(self, conv: UUID) -> None:
        """窗口删了：排着的丢掉，计时器和正在跑的那一轮都停掉（不然它跑完会往删掉的窗口里写东西）。"""
        r = self.rooms.pop(conv, None)
        for t in (r.timer, r.running) if r else ():
            if t and not t.done() and t is not asyncio.current_task():
                t.cancel()
        if r:
            for q in r.listeners:
                q.put_nowait(None)

    async def idle(self, conv: UUID) -> None:
        """测试用：等这个窗口排着的、正在跑的都跑完。"""
        while (r := self.rooms.get(conv)) and ((r.timer and not r.timer.done()) or (r.running and not r.running.done())):
            await asyncio.sleep(0.01)

"""灰区判读器（2026-09-28，Tilia提议：照Quercus那样让便宜的大模型判，不用本地精排模型）。

本地精排（bge-reranker）是「这段能不能回答这个问题」的模型，拿来判「这条记忆跟这句闲聊有没有关系」分辨力弱
（评测集上修好分数后细读反而净亏）。这里改成：只把门槛附近的那几条（灰区）连同最近几句一起给 DeepSeek Flash，
让它逐条判 2 = 这会儿该想起来、1 = 沾边、0 = 不相关。一轮最多多一次调用（约 0.0001 美元），没有灰区就不调。
接口跟精排一样给 0~1 的分（2→1.0、1→0.2、0→0.0），记忆服务那边照这一档的精排门槛定档；
出错、超时、看不懂 → 抛出去，记忆服务照复判前的门槛走。"""
from __future__ import annotations

import json
import re

from llm.router import call
from llm.types import Block, ChatRequest, Msg

SCORE = {2: 1.0, 1: 0.2, 0: 0.0}

PROMPT = {
    "zh": """TA 刚说了一句话。下面是几条关于 TA 的旧记忆，判断每一条这会儿该不该浮上来给聊天的那个 AI 看。

最近几句：
{recent}
TA 这句：{text}

记忆：
{items}

逐条打分：2 = 跟这句直接相关，这会儿想起来正好；1 = 沾边，想起来也不奇怪；0 = 不相关，或者只是字面上撞了词。
只输出一个 JSON，键是编号：{{"1": 2, "2": 0}}""",
    "en": """They just said something. Below are a few old memories about them; decide whether each should surface for the
chatting AI right now.

Recent lines:
{recent}
Their line: {text}

Memories:
{items}

Score each: 2 = directly relevant, good to recall now; 1 = related, fine to recall; 0 = unrelated or only shares a word.
Output one JSON object keyed by number: {{"1": 2, "2": 0}}""",
}


class LLMJudge:
    """记忆服务的 rerank_pick 认 ascore（异步）和 timeout。"""
    timeout = 8.0

    def __init__(self, adapter, model: str, recent: list[str] | None = None, lang: str = "zh"):
        self.adapter, self.model, self.recent, self.lang = adapter, model, recent or [], lang
        self.usage = None                 # 最近一次花的 token（大脑记账）

    async def ascore(self, query: str, docs: list[str]) -> list[float]:
        items = "\n".join(f"{i}. {d}" for i, d in enumerate(docs, start=1))
        prompt = PROMPT[self.lang].format(text=query, items=items, recent="\n".join(self.recent[-3:]) or "（刚开始聊）")
        reply = await call(self.adapter, ChatRequest(model=self.model, system=[Block("只输出 JSON。")],
                                                     messages=[Msg("user", prompt)], max_tokens=200, thinking=False))
        self.usage = reply.usage
        m = re.search(r"\{.*\}", reply.text or "", re.S)
        if not m:
            raise ValueError(f"judge gave no JSON: {(reply.text or '')[:100]!r}")
        got = json.loads(m.group(0))
        return [SCORE.get(int(got.get(str(i), 0)), 0.0) for i in range(1, len(docs) + 1)]

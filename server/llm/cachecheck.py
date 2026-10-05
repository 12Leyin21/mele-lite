"""缓存体检（给自填地址的用户）：同一个请求连发两次，看第二次有没有走缓存。会花一点钱，只能用户自己按。

结论分三种，绝不把后两种混成一个坏消息：
- hit：第二次确实从缓存读了
- miss：对方报了缓存用量，两次都是 0（也可能是开头太短，没到这个模型的最小缓存长度）
- unknown：这次没测出来——请求没发成功，或者对方根本不报缓存用量"""
from .errors import LLMError
from .router import call
from .types import Block, ChatRequest, Msg


async def cache_check(adapter, model: str, system_text: str, tools) -> dict:
    req = ChatRequest(model=model, system=[Block(system_text, cache=True)],
                      messages=[Msg("user", "ping，回一个字就行")], tools=list(tools), max_tokens=16)
    try:
        r1 = await call(adapter, req)
        r2 = await call(adapter, req)
    except LLMError as e:
        return {"result": "unknown", "reason": f"请求没发成功（{e.kind}），这次没测出来"}
    if r2.usage.cache_read > 0:
        return {"result": "hit", "reason": f"第二次有 {r2.usage.cache_read} 个 token 走了缓存"}
    if not (r1.usage.cache_known and r2.usage.cache_known):
        return {"result": "unknown", "reason": "这个地址不报缓存用量，这次没测出来"}
    return {"result": "miss", "reason": "两次都没有走缓存（也可能是开头太短，没到这个模型的最小缓存长度）"}

"""钥匙：这个用户用哪家、哪把 key、哪个模型。

现在只有本地文件一种（本机测试用，.local/ 不进仓库）；以后账号那块在这里接上「用户存的加密 key」，
会员那块接上「我们的 key + 额度」，大脑不用改。

.local/keys.toml 的样子：
    [default]
    provider = "deepseek"          # anthropic / deepseek / openai / openai-compatible / gemini
    api_key = "sk-..."
    chat_model = "deepseek-flash"
    # ledger_model = "..."         # 不写就用模型清单里同一家的便宜型号；清单外的模型用它自己
    # age_model = "..."            # 压旧天用哪个；不写就用模型清单里配的，清单外的跟 ledger_model 一样
    # base_url = "https://..."     # 中转站 / 自部署才要
"""
import tomllib
from pathlib import Path

from .catalog import lookup
from .router import PROVIDERS, Route


class FileKeys:
    """所有用户共用 [default] 这一把——只在本机测试时这样。"""

    def __init__(self, path):
        data = tomllib.loads(Path(path).read_text(encoding="utf-8"))
        d = data["default"]
        if d["provider"] not in PROVIDERS:
            raise ValueError(f"provider must be one of {PROVIDERS}, got {d['provider']!r}")
        chat = d["chat_model"]
        info = lookup(chat)
        self._route = Route(
            provider=d["provider"], api_key=d["api_key"], chat_model=chat,
            ledger_model=d.get("ledger_model") or (info.ledger_model if info else chat),
            base_url=d.get("base_url"),
            age_model=d.get("age_model") or (info.age_model if info else None),
        )

    def route_for(self, user_id) -> Route:
        return self._route

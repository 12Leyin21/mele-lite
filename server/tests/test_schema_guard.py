"""建表脚本守卫（10-01）：同一个约束在脚本里加了好几遍时，每一遍的列表必须一模一样。

每次重启都会把整份脚本从头跑一遍；前面的旧写法少了新类型，库里一有新类型的行，旧那遍就加不上、整份建表回滚、服务器起不来
（09-30 倒回记账 far_date、10-01 钟 morning 各踩过一次）。"""
import re
from pathlib import Path

SCHEMAS = [Path(__file__).resolve().parent.parent / "brain" / "schema.sql",
           Path(__file__).resolve().parent.parent / "memory" / "schema.sql"]
ADD = re.compile(r"ADD CONSTRAINT (\w+)\s+CHECK \((.*?)\);", re.S)


def test_repeated_check_constraints_are_identical():
    for path in SCHEMAS:
        seen: dict[str, str] = {}
        for name, body in ADD.findall(path.read_text()):
            body = " ".join(body.split())
            assert seen.setdefault(name, body) == body, f"{path.name}: {name} 前后几遍不一样，旧那遍会在重启时失败"

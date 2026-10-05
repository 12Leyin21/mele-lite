-- 记忆服务的表。重复执行安全（IF NOT EXISTS）。
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS memories (
  id               BIGSERIAL PRIMARY KEY,
  user_id          UUID        NOT NULL,
  kind             TEXT        NOT NULL DEFAULT 'memory'
                   CHECK (kind IN ('memory', 'core', 'person', 'about', 'diary')),
  content          TEXT        NOT NULL,
  name             TEXT,                       -- 人物卡才有：名字
  aliases          TEXT[]      NOT NULL DEFAULT '{}',  -- 人物卡：别名
  relation         TEXT,                       -- 人物卡：是谁（跟用户的关系）
  impression       TEXT        NOT NULL DEFAULT '',   -- 人物卡：它自己的印象（content 是用户写的「要记得」）
  created_by       TEXT        NOT NULL DEFAULT 'user' CHECK (created_by IN ('user', 'ai')),
  updated_by       TEXT        NOT NULL DEFAULT 'user' CHECK (updated_by IN ('user', 'ai')),
  importance       SMALLINT    NOT NULL DEFAULT 5 CHECK (importance BETWEEN 1 AND 10),
  valence          REAL        NOT NULL DEFAULT 0 CHECK (valence BETWEEN -1 AND 1),
  arousal          REAL        NOT NULL DEFAULT 0 CHECK (arousal BETWEEN 0 AND 1),
  tags             TEXT[]      NOT NULL DEFAULT '{}',
  resolved         BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_recalled_at TIMESTAMPTZ,
  recall_count     INT         NOT NULL DEFAULT 0,
  rewritten_at     TIMESTAMPTZ,                -- 内容最后一次改写/合并（淡去的时钟从这里重新算）
  embedding        vector(1024),               -- 算不出来时先空着，backfill 补
  search_tsv       tsvector                    -- jieba 分好的词
);

-- 每个用户几千条以内，按 user_id 过滤后精确算相似度就够快；
-- 不建 HNSW：带 user_id 过滤时近似索引会漏结果。
-- 2026-09-26 加「关于 TA」（about）：老库的约束换成新的
ALTER TABLE memories ADD COLUMN IF NOT EXISTS rewritten_at TIMESTAMPTZ;
ALTER TABLE memories DROP CONSTRAINT IF EXISTS memories_kind_check;
ALTER TABLE memories ADD CONSTRAINT memories_kind_check CHECK (kind IN ('memory', 'core', 'person', 'about', 'diary'));   -- diary：Ta 的日记（10-01）

CREATE INDEX IF NOT EXISTS memories_user_kind_idx ON memories (user_id, kind);
CREATE INDEX IF NOT EXISTS memories_tsv_idx ON memories USING GIN (search_tsv);
CREATE INDEX IF NOT EXISTS memories_no_embedding_idx ON memories (id) WHERE embedding IS NULL;

CREATE TABLE IF NOT EXISTS sticky_notes (
  user_id    UUID        PRIMARY KEY,
  text       TEXT        NOT NULL DEFAULT '',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

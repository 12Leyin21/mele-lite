# Mele Host 主程序（10-04）。CPU 版 PyTorch（不带 CUDA，镜像小一半）；ffmpeg 给「耳朵」解音频；tzdata 给按 TA 那边时区算的钟。
# pyproject 的打包列表里有 web（本机测试台），Host 不要它，所以不 pip install .：只装依赖，代码直接从 /app 跑。
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    HF_HOME=/data/hf NEWAPP_FILES_DIR=/data/files \
    NEWAPP_HOST=1 NEWAPP_PATROL=1

RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg tzdata && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY pyproject.toml ./
RUN python -c "import tomllib;p=tomllib.load(open('pyproject.toml','rb'))['project'];print('\n'.join(p['dependencies']+p['optional-dependencies']['embed']))" > /tmp/req.txt \
 && pip install --no-cache-dir --extra-index-url https://download.pytorch.org/whl/cpu -r /tmp/req.txt

COPY api ./api
COPY brain ./brain
COPY food ./food
COPY llm ./llm
COPY memory ./memory
COPY music ./music
COPY patrol ./patrol
COPY push ./push
COPY NOTICE.md ./

VOLUME ["/data"]
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8080/health')"
CMD ["python", "-m", "api", "--host", "0.0.0.0", "--port", "8080"]
